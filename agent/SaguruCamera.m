// SaguruCamera: the part of Saguru's agent that gives an app in the iOS Simulator a camera.
// The Simulator has none, so the app is handed a pretend one. Its pictures come from Saguru on the Mac
// (an image, the Mac's camera, an iPhone used as a camera) through a file both sides map into memory:
//   frame.bgra   64-byte header (magic, sequence, width, height, bytes per row) followed by BGRA pixels.
// The sequence is odd while Saguru is writing a frame, so a half-written one is never used.
//
// What is covered: finding the camera, permission, AVCaptureSession with video frames in the size the
// session preset asks for, connections (rotation and mirroring), the preview layer, machine-readable
// codes (QR) and still photos. Apple's own camera screens are not.
//
// The pretend objects are never initialised the normal way, so any method Apple's class would answer
// from its own inner state must be answered here instead. The ones written out below return something
// sensible; every other one is given a harmless answer (nil, zero, nothing) by Net() at the bottom and
// is logged the first time an app calls it, so a gap shows up in the log instead of as a crash.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <dlfcn.h>

static NSString *gFramePath;
static const uint8_t *gMap;
static size_t gMapSize;
static uint32_t gLastSequence;
static CVPixelBufferRef gSource;   // the picture as Saguru sent it, upright
static CVPixelBufferRef gPixels;   // the same, cut and scaled to what the session preset asks for
static int gWantW = 1080, gWantH = 1920, gShapedW, gShapedH;
static uint32_t gShapedFor;
static NSString *gFolder;
static NSArray<NSDictionary *> *gCodes;   // payload + normalized box (top-left origin)
static BOOL gDetecting;
static NSHashTable *gSessions, *gLayers;
static dispatch_queue_t gFeed, gDetect;
static dispatch_source_t gTimer;
static CIContext *gContext;
static char kInputs, kOutputs, kRunning, kTypes, kSub, kBusy, kPickerCamera, kPickerShown, kConn, kAdded, kPreset;

// MARK: Pretend objects (never initialised the normal way: created bare and answered by these overrides)

/// The one format the pretend camera offers: what a phone's wide camera reports for 1080p video.
@interface SaguruFormat : AVCaptureDeviceFormat @end
@implementation SaguruFormat
- (CMFormatDescriptionRef)formatDescription {
    static CMVideoFormatDescriptionRef d; static dispatch_once_t once;
    dispatch_once(&once, ^{ CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 1920, 1080, NULL, &d); });
    return d;
}
- (AVMediaType)mediaType { return AVMediaTypeVideo; }
- (float)videoFieldOfView { return 69; }
- (CGFloat)videoMaxZoomFactor { return 1; }
- (CGFloat)videoZoomFactorUpscaleThreshold { return 1; }
- (NSArray *)supportedMaxPhotoDimensions { CMVideoDimensions a = {1920, 1440}, b = {4032, 3024}; return @[[NSValue valueWithBytes:&a objCType:@encode(CMVideoDimensions)], [NSValue valueWithBytes:&b objCType:@encode(CMVideoDimensions)]]; }
- (CMVideoDimensions)highResolutionStillImageDimensions { return (CMVideoDimensions){4032, 3024}; }
- (NSArray *)videoSupportedFrameRateRanges { return @[]; }
- (float)minISO { return 30; }
- (float)maxISO { return 3000; }
- (CMTime)minExposureDuration { return CMTimeMake(1, 10000); }
- (CMTime)maxExposureDuration { return CMTimeMake(1, 3); }
- (BOOL)isVideoBinned { return NO; }
- (BOOL)isVideoHDRSupported { return NO; }
- (BOOL)isVideoStabilizationModeSupported:(AVCaptureVideoStabilizationMode)m { return NO; }
- (AVCaptureAutoFocusSystem)autoFocusSystem { return AVCaptureAutoFocusSystemPhaseDetection; }
- (NSArray *)supportedColorSpaces { return @[@(AVCaptureColorSpace_sRGB)]; }
- (BOOL)isHighestPhotoQualitySupported { return NO; }
- (BOOL)isMultiCamSupported { return NO; }
- (NSArray *)unsupportedCaptureOutputClasses { return @[]; }
// AVFoundation asks a format for its inner description (when making default photo settings, for one).
// There is none here, and it copes with nil the same way it does with a camera that has no format.
- (id)figCaptureSourceVideoFormat { return nil; }
@end
static id Format(void) { static id f; static dispatch_once_t once; dispatch_once(&once, ^{ f = class_createInstance(SaguruFormat.class, 0); }); return f; }

@interface SaguruCamera : AVCaptureDevice @property (nonatomic) AVCaptureDevicePosition spot; @end
@implementation SaguruCamera {
    AVCaptureTorchMode _torch; AVCaptureFocusMode _focus; AVCaptureExposureMode _exposure; CGPoint _focusPoint, _exposurePoint; CGFloat _zoom;
}
- (NSString *)uniqueID { return self.spot == AVCaptureDevicePositionFront ? @"dev.saguru.camera.front" : @"dev.saguru.camera.back"; }
- (NSString *)modelID { return @"Saguru"; }
- (NSString *)localizedName { return self.spot == AVCaptureDevicePositionFront ? @"Cámara frontal de Saguru" : @"Cámara trasera de Saguru"; }
- (AVCaptureDevicePosition)position { return self.spot; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)hasMediaType:(AVMediaType)type { return [type isEqualToString:AVMediaTypeVideo]; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)lockForConfiguration:(NSError **)error { return YES; }
- (void)unlockForConfiguration {}
- (NSArray *)formats { return @[Format()]; }
- (id)activeFormat { return Format(); }
- (void)setActiveFormat:(id)f {}
- (BOOL)hasTorch { return YES; }
- (BOOL)isTorchAvailable { return YES; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)m { return YES; }
- (AVCaptureTorchMode)torchMode { return _torch; }
- (void)setTorchMode:(AVCaptureTorchMode)m { _torch = m; }
- (BOOL)isTorchActive { return _torch == AVCaptureTorchModeOn; }
- (float)torchLevel { return _torch == AVCaptureTorchModeOn ? 1 : 0; }
- (BOOL)setTorchModeOnWithLevel:(float)l error:(NSError **)e { _torch = AVCaptureTorchModeOn; return YES; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)m { return YES; }
- (AVCaptureFocusMode)focusMode { return _focus; }
- (void)setFocusMode:(AVCaptureFocusMode)m { _focus = m; }
- (BOOL)isAdjustingFocus { return NO; }
- (float)lensPosition { return 0.5; }
- (NSInteger)minimumFocusDistance { return -1; }
- (BOOL)isLockingFocusWithCustomLensPositionSupported { return NO; }
- (BOOL)isAutoFocusRangeRestrictionSupported { return NO; }
- (AVCaptureAutoFocusRangeRestriction)autoFocusRangeRestriction { return AVCaptureAutoFocusRangeRestrictionNone; }
- (void)setAutoFocusRangeRestriction:(AVCaptureAutoFocusRangeRestriction)r {}
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isSmoothAutoFocusEnabled { return NO; }
- (void)setSmoothAutoFocusEnabled:(BOOL)b {}
- (BOOL)isFocusPointOfInterestSupported { return YES; }
- (CGPoint)focusPointOfInterest { return _focusPoint; }
- (void)setFocusPointOfInterest:(CGPoint)p { _focusPoint = p; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)m { return m != AVCaptureExposureModeCustom; }
- (AVCaptureExposureMode)exposureMode { return _exposure; }
- (void)setExposureMode:(AVCaptureExposureMode)m { _exposure = m; }
- (BOOL)isAdjustingExposure { return NO; }
- (BOOL)isExposurePointOfInterestSupported { return YES; }
- (CGPoint)exposurePointOfInterest { return _exposurePoint; }
- (void)setExposurePointOfInterest:(CGPoint)p { _exposurePoint = p; }
- (float)exposureTargetBias { return 0; }
- (float)minExposureTargetBias { return 0; }
- (float)maxExposureTargetBias { return 0; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)m { return m == AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)m {}
- (BOOL)isAdjustingWhiteBalance { return NO; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return NO; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)b {}
- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)p { return YES; }
- (CGFloat)videoZoomFactor { return _zoom < 1 ? 1 : _zoom; }
- (void)setVideoZoomFactor:(CGFloat)z { _zoom = z; }
- (void)rampToVideoZoomFactor:(CGFloat)z withRate:(float)r { _zoom = z; }
- (void)cancelVideoZoomRamp {}
- (BOOL)isRampingVideoZoom { return NO; }
- (CGFloat)minAvailableVideoZoomFactor { return 1; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1; }
- (CMTime)activeVideoMinFrameDuration { return CMTimeMake(1, 30); }
- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMinFrameDuration:(CMTime)t {}
- (void)setActiveVideoMaxFrameDuration:(CMTime)t {}
- (NSArray *)constituentDevices { return @[]; }
- (BOOL)isVirtualDevice { return NO; }
@end

@interface SaguruInput : AVCaptureDeviceInput @property (nonatomic, strong) AVCaptureDevice *fake; @end
@implementation SaguruInput
- (AVCaptureDevice *)device { return self.fake; }
- (NSArray *)ports { return @[]; }
@end

/// The link between the camera and one output or preview layer. Apps use it to turn the picture
/// (a phone's sensor lies on its side, so 90° is upright) and to mirror it.
@interface SaguruConnection : AVCaptureConnection @property (nonatomic, weak) id owner; @property (nonatomic) CGFloat angle; @property (nonatomic) BOOL mirrored, manualMirror, off; @end
@implementation SaguruConnection
- (AVCaptureOutput *)output { id o = self.owner; return [o isKindOfClass:AVCaptureOutput.class] ? o : nil; }
- (AVCaptureVideoPreviewLayer *)videoPreviewLayer { id o = self.owner; return [o isKindOfClass:AVCaptureVideoPreviewLayer.class] ? o : nil; }
- (NSArray *)inputPorts { return @[]; }
- (NSArray *)audioChannels { return @[]; }
- (BOOL)isEnabled { return !self.off; }
- (void)setEnabled:(BOOL)e { self.off = !e; }
- (BOOL)isActive { return !self.off; }
- (BOOL)isVideoRotationAngleSupported:(CGFloat)a { return a == 0 || a == 90 || a == 180 || a == 270; }
- (CGFloat)videoRotationAngle { return self.angle; }
- (void)setVideoRotationAngle:(CGFloat)a { if ([self isVideoRotationAngleSupported:a]) self.angle = a; }
- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation { return self.angle == 90 ? AVCaptureVideoOrientationPortrait : self.angle == 270 ? AVCaptureVideoOrientationPortraitUpsideDown : self.angle == 180 ? AVCaptureVideoOrientationLandscapeLeft : AVCaptureVideoOrientationLandscapeRight; }
- (void)setVideoOrientation:(AVCaptureVideoOrientation)o { self.angle = o == AVCaptureVideoOrientationPortrait ? 90 : o == AVCaptureVideoOrientationPortraitUpsideDown ? 270 : o == AVCaptureVideoOrientationLandscapeLeft ? 180 : 0; }
- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored { return self.mirrored; }
- (void)setVideoMirrored:(BOOL)m { self.mirrored = m; }
- (BOOL)automaticallyAdjustsVideoMirroring { return !self.manualMirror; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)a { self.manualMirror = !a; }
- (BOOL)isVideoStabilizationSupported { return NO; }
- (AVCaptureVideoStabilizationMode)preferredVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (void)setPreferredVideoStabilizationMode:(AVCaptureVideoStabilizationMode)m {}
- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (CGFloat)videoMaxScaleAndCropFactor { return 1; }
- (CGFloat)videoScaleAndCropFactor { return 1; }
- (void)setVideoScaleAndCropFactor:(CGFloat)f {}
- (BOOL)isVideoMinFrameDurationSupported { return NO; }
- (BOOL)isVideoMaxFrameDurationSupported { return NO; }
- (CMTime)videoMinFrameDuration { return CMTimeMake(1, 30); }
- (CMTime)videoMaxFrameDuration { return CMTimeMake(1, 30); }
- (void)setVideoMinFrameDuration:(CMTime)t {}
- (void)setVideoMaxFrameDuration:(CMTime)t {}
- (BOOL)isCameraIntrinsicMatrixDeliverySupported { return NO; }
@end

/// What a photo request was resolved to; photo delegates get it with every call.
@interface SaguruResolved : AVCaptureResolvedPhotoSettings @property (nonatomic) int64_t number; @property (nonatomic) CMVideoDimensions size; @end
@implementation SaguruResolved
- (int64_t)uniqueID { return self.number; }
- (CMVideoDimensions)photoDimensions { return self.size; }
- (CMVideoDimensions)rawPhotoDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)previewDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)embeddedThumbnailDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)rawEmbeddedThumbnailDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)portraitEffectsMatteDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)livePhotoMovieDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)deferredPhotoProxyDimensions { return (CMVideoDimensions){0, 0}; }
- (CMTimeRange)photoProcessingTimeRange { return kCMTimeRangeZero; }
- (NSUInteger)expectedPhotoCount { return 1; }
@end

@interface SaguruCode : AVMetadataMachineReadableCodeObject
@property (nonatomic, copy) NSString *text; @property (nonatomic) CGRect box; @end
@implementation SaguruCode
- (NSString *)stringValue { return self.text; }
- (AVMetadataObjectType)type { return AVMetadataObjectTypeQRCode; }
- (CGRect)bounds { return self.box; }
- (NSArray *)corners { CGRect b = self.box; NSMutableArray *a = [NSMutableArray array];
    for (NSValue *p in @[@(CGPointMake(CGRectGetMinX(b), CGRectGetMinY(b))), @(CGPointMake(CGRectGetMinX(b), CGRectGetMaxY(b))), @(CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b))), @(CGPointMake(CGRectGetMaxX(b), CGRectGetMinY(b)))])
        [a addObject:CFBridgingRelease(CGPointCreateDictionaryRepresentation(p.CGPointValue))];
    return a; }
- (CMTime)time { return CMClockGetTime(CMClockGetHostTimeClock()); }
- (CMTime)duration { return kCMTimeInvalid; }
@end

@interface SaguruPhoto : AVCapturePhoto @property (nonatomic, strong) NSData *jpeg; @property (nonatomic, strong) SaguruResolved *resolved; @end
@implementation SaguruPhoto { CGImageRef _image; }
- (NSData *)fileDataRepresentation { return self.jpeg; }
- (CGImageRef)CGImageRepresentation {
    if (!_image && self.jpeg) { CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)self.jpeg, NULL); if (source) { _image = CGImageSourceCreateImageAtIndex(source, 0, NULL); CFRelease(source); } }
    return _image;
}
- (CVPixelBufferRef)pixelBuffer { return NULL; }
- (NSDictionary *)metadata { return @{(id)kCGImagePropertyOrientation: @1}; }
- (AVCaptureResolvedPhotoSettings *)resolvedSettings { return self.resolved; }
- (NSInteger)photoCount { return 1; }
- (NSInteger)sequenceCount { return 1; }
- (void)saguruCleanUp { if (_image) { CGImageRelease(_image); _image = NULL; } }
- (BOOL)isRawPhoto { return NO; }
- (CMTime)timestamp { return CMClockGetTime(CMClockGetHostTimeClock()); }
@end

static id Bare(Class c) { return class_createInstance(c, 0); }
/// The app can ask for a back and a front camera; both exist and show the same source.
static AVCaptureDevice *Camera(AVCaptureDevicePosition position) {
    static SaguruCamera *back, *front; static dispatch_once_t once;
    dispatch_once(&once, ^{ back = Bare(SaguruCamera.class); back.spot = AVCaptureDevicePositionBack; front = Bare(SaguruCamera.class); front.spot = AVCaptureDevicePositionFront; });
    return position == AVCaptureDevicePositionFront ? front : back;
}
static BOOL IsOurs(id device) { return [device isKindOfClass:SaguruCamera.class]; }

// MARK: The picture

/// Takes the newest whole frame from the shared file, if there is one since the last look.
static void ReadFrame(void) {
    if (!gMap) {
        int file = open(gFramePath.fileSystemRepresentation, O_RDONLY);
        if (file < 0) return;
        off_t size = lseek(file, 0, SEEK_END);
        if (size > 64) { void *map = mmap(NULL, (size_t)size, PROT_READ, MAP_SHARED, file, 0); if (map != MAP_FAILED) { gMap = map; gMapSize = (size_t)size; } }
        close(file);
        if (!gMap) return;
    }
    const volatile uint32_t *header = (const volatile uint32_t *)gMap;
    uint32_t before = header[1];
    if (header[0] != 0x4D434753 || (before & 1) || before == gLastSequence) return;
    uint32_t width = header[2], height = header[3], row = header[4];
    if (!width || !height || row < width * 4 || 64 + (size_t)row * height > gMapSize) return;
    CVPixelBufferRef pixels = NULL;
    CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &pixels);
    if (!pixels) return;
    CVPixelBufferLockBaseAddress(pixels, 0);
    uint8_t *target = CVPixelBufferGetBaseAddress(pixels); size_t targetRow = CVPixelBufferGetBytesPerRow(pixels);
    for (uint32_t y = 0; y < height; y++) memcpy(target + y * targetRow, gMap + 64 + (size_t)y * row, width * 4);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    // Saguru started another frame meanwhile: this copy may be mixed, so it is dropped.
    if (header[1] != before) { CVPixelBufferRelease(pixels); return; }
    if (gSource) CVPixelBufferRelease(gSource);
    gSource = pixels;
    gLastSequence = before;
}

/// Cuts and scales the picture to the size the session preset stands for, the way a camera fills its
/// frame: the middle is kept, whatever sticks out is lost.
static void Shape(void) {
    if (!gSource) return;
    int w = gWantW, h = gWantH;
    if (gPixels && gShapedFor == gLastSequence && gShapedW == w && gShapedH == h) return;
    size_t sw = CVPixelBufferGetWidth(gSource), sh = CVPixelBufferGetHeight(gSource);
    CVPixelBufferRef out = NULL;
    if ((int)sw == w && (int)sh == h) out = CVPixelBufferRetain(gSource);
    else {
        CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &out);
        if (!out) return;
        CGFloat scale = MAX((CGFloat)w / sw, (CGFloat)h / sh);
        CGAffineTransform t = CGAffineTransformMakeTranslation((w - sw * scale) / 2, (h - sh * scale) / 2);
        [gContext render:[[CIImage imageWithCVPixelBuffer:gSource] imageByApplyingTransform:CGAffineTransformScale(t, scale, scale)] toCVPixelBuffer:out];
    }
    if (gPixels) CVPixelBufferRelease(gPixels);
    gPixels = out; gShapedFor = gLastSequence; gShapedW = w; gShapedH = h;
}

/// Looks for QR codes in the current picture, off the feeding queue. Core Image's detector runs on the
/// CPU; Vision's often cannot start in the Simulator.
static void FindCodes(void) {
    if (gDetecting || !gPixels) return;
    gDetecting = YES;
    CVPixelBufferRef pixels = CVPixelBufferRetain(gPixels);
    dispatch_async(gDetect, ^{
        static CIDetector *detector; static dispatch_once_t once;
        dispatch_once(&once, ^{ detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:gContext options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}]; });
        CGFloat w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels);
        NSMutableArray *codes = [NSMutableArray array];
        for (CIQRCodeFeature *f in [detector featuresInImage:[CIImage imageWithCVPixelBuffer:pixels]]) if (f.messageString) {
            CGRect b = f.bounds; // pixels, bottom-left origin
            [codes addObject:@{@"text": f.messageString, @"box": [NSValue valueWithCGRect:CGRectMake(b.origin.x / w, 1 - (b.origin.y + b.size.height) / h, b.size.width / w, b.size.height / h)]}];
        }
        CVPixelBufferRelease(pixels);
        dispatch_async(gFeed, ^{ gCodes = codes; gDetecting = NO; });
    });
}

// MARK: Feeding

static NSArray *Listed(id session, char *key);

static SaguruConnection *ConnectionOf(id owner) { return objc_getAssociatedObject(owner, &kConn); }
/// Outputs start lying on their side like the sensor (0°); a preview layer starts upright (90°).
static SaguruConnection *ConnectionFor(id owner) {
    @synchronized (gSessions) {
        SaguruConnection *c = objc_getAssociatedObject(owner, &kConn);
        if (!c) { c = Bare(SaguruConnection.class); c.owner = owner; c.angle = [owner isKindOfClass:AVCaptureVideoPreviewLayer.class] ? 90 : 0; objc_setAssociatedObject(owner, &kConn, c, OBJC_ASSOCIATION_RETAIN); }
        return c;
    }
}
/// Quarter turns to the right that take the upright picture to a connection's angle.
static int Turns(CGFloat angle) { return (((int)lround(angle / 90) - 1) % 4 + 4) % 4; }
static BOOL UsesFront(AVCaptureSession *session) {
    for (id input in Listed(session, &kInputs)) if ([input isKindOfClass:SaguruInput.class] && ((SaguruInput *)input).fake.position == AVCaptureDevicePositionFront) return YES;
    return NO;
}

/// The current picture the way one output wants it: pixel format, turned, mirrored. Real cameras hand
/// out YUV unless told otherwise, and apps that read the brightness plane depend on getting what they set.
static CVPixelBufferRef CopyVariant(OSType format, int turns, BOOL mirror) {
    if (format == kCVPixelFormatType_32BGRA && !turns && !mirror) return CVPixelBufferRetain(gPixels);
    static struct { CVPixelBufferRef pixels; CVPixelBufferRef from; uint32_t sequence; OSType format; int turns; BOOL mirror; } made[4];
    static int next;
    for (int i = 0; i < 4; i++) if (made[i].pixels && made[i].from == gPixels && made[i].sequence == gShapedFor && made[i].format == format && made[i].turns == turns && made[i].mirror == mirror) return CVPixelBufferRetain(made[i].pixels);
    size_t w = CVPixelBufferGetWidth(gPixels), h = CVPixelBufferGetHeight(gPixels);
    CVPixelBufferRef out = NULL;
    CVPixelBufferCreate(NULL, turns % 2 ? h : w, turns % 2 ? w : h, format, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &out);
    if (!out) return CVPixelBufferRetain(gPixels);
    CIImage *image = [CIImage imageWithCVPixelBuffer:gPixels];
    if (mirror) image = [image imageByApplyingCGOrientation:kCGImagePropertyOrientationUpMirrored];
    static const CGImagePropertyOrientation way[4] = { kCGImagePropertyOrientationUp, kCGImagePropertyOrientationRight, kCGImagePropertyOrientationDown, kCGImagePropertyOrientationLeft };
    if (turns) image = [image imageByApplyingCGOrientation:way[turns]];
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
    [gContext render:image toCVPixelBuffer:out];
    int slot = next++ % 4;
    if (made[slot].pixels) CVPixelBufferRelease(made[slot].pixels);
    made[slot].pixels = CVPixelBufferRetain(out); made[slot].from = gPixels; made[slot].sequence = gShapedFor; made[slot].format = format; made[slot].turns = turns; made[slot].mirror = mirror;
    return out;
}
static CMSampleBufferRef CopySample(CVPixelBufferRef pixels) {
    CMSampleTimingInfo timing = { CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid };
    CMVideoFormatDescriptionRef format = NULL; CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixels, &format);
    CMSampleBufferRef sample = NULL; CMSampleBufferCreateReadyWithImageBuffer(NULL, pixels, format, &timing, &sample);
    if (format) CFRelease(format);
    return sample;
}

static void Tick(void) {
    ReadFrame();
    Shape();
    if (!gPixels) return;
    static NSInteger count; count++;
    if (count % 12 == 0) FindCodes();
    NSArray *sessions;
    @synchronized (gSessions) { sessions = gSessions.allObjects; }
    for (AVCaptureSession *session in sessions) {
        if (![objc_getAssociatedObject(session, &kRunning) boolValue]) continue;
        for (AVCaptureOutput *output in Listed(session, &kOutputs)) {
            SaguruConnection *connection = ConnectionOf(output);
            if (connection.off) continue;
            if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) {
                AVCaptureVideoDataOutput *video = (id)output; id delegate = video.sampleBufferDelegate;
                if (!delegate) continue;
                // Like a real camera, a frame is dropped while the app is still busy with the previous one.
                if ([objc_getAssociatedObject(video, &kBusy) boolValue]) continue;
                OSType format = [video.videoSettings[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue] ?: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
                CVPixelBufferRef pixels = CopyVariant(format, Turns(connection.angle), connection.mirrored);
                CMSampleBufferRef sample = CopySample(pixels); CVPixelBufferRelease(pixels);
                if (!sample) continue;
                objc_setAssociatedObject(video, &kBusy, @YES, OBJC_ASSOCIATION_RETAIN);
                dispatch_async(video.sampleBufferCallbackQueue ?: dispatch_get_main_queue(), ^{
                    [delegate captureOutput:video didOutputSampleBuffer:sample fromConnection:connection]; CFRelease(sample);
                    objc_setAssociatedObject(video, &kBusy, @NO, OBJC_ASSOCIATION_RETAIN); });
            } else if ([output isKindOfClass:AVCaptureMetadataOutput.class] && count % 10 == 0 && gCodes.count) {
                AVCaptureMetadataOutput *meta = (id)output; id delegate = meta.metadataObjectsDelegate;
                NSArray *types = objc_getAssociatedObject(meta, &kTypes);
                if (!delegate || ![types containsObject:AVMetadataObjectTypeQRCode]) continue;
                NSMutableArray *found = [NSMutableArray array];
                for (NSDictionary *code in gCodes) { SaguruCode *c = Bare(SaguruCode.class); c.text = code[@"text"]; c.box = [code[@"box"] CGRectValue]; [found addObject:c]; }
                dispatch_async(meta.metadataObjectsCallbackQueue ?: dispatch_get_main_queue(), ^{ [delegate captureOutput:meta didOutputMetadataObjects:found fromConnection:connection]; });
            }
        }
    }
    if (count % 2 == 0) {
        CVPixelBufferRef shown = CVPixelBufferRetain(gPixels);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (AVCaptureVideoPreviewLayer *layer in gLayers.allObjects) {
                CALayer *sub = objc_getAssociatedObject(layer, &kSub);
                if (!sub) { sub = [CALayer layer]; sub.masksToBounds = YES; [layer addSublayer:sub]; layer.masksToBounds = YES; objc_setAssociatedObject(layer, &kSub, sub, OBJC_ASSOCIATION_RETAIN); }
                // The layer shows the picture upright unless the app turned its connection; the front
                // camera is shown mirrored, like a mirror, unless the app decides otherwise.
                SaguruConnection *connection = ConnectionOf(layer);
                int turns = connection ? Turns(connection.angle) : 0;
                AVCaptureSession *session = layer.session;
                BOOL mirror = connection.manualMirror ? connection.mirrored : (session && UsesFront(session));
                CGSize size = layer.bounds.size;
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                sub.bounds = turns % 2 ? CGRectMake(0, 0, size.height, size.width) : CGRectMake(0, 0, size.width, size.height);
                sub.position = CGPointMake(size.width / 2, size.height / 2);
                CGAffineTransform t = CGAffineTransformMakeRotation(turns * M_PI_2);
                sub.affineTransform = mirror ? CGAffineTransformScale(t, -1, 1) : t;
                sub.contents = (__bridge id)CVPixelBufferGetIOSurface(shown);
                NSString *g = layer.videoGravity;
                sub.contentsGravity = [g isEqual:AVLayerVideoGravityResizeAspectFill] ? kCAGravityResizeAspectFill : ([g isEqual:AVLayerVideoGravityResize] ? kCAGravityResize : kCAGravityResizeAspect);
                [CATransaction commit];
            }
            CVPixelBufferRelease(shown);
        });
    }
}

// MARK: Swizzles

#define SWAP(cls, sel, fn, store) do { Method m = class_getInstanceMethod(cls, @selector(sel)); if (m) store = (void *)method_setImplementation(m, (IMP)fn); else NSLog(@"Saguru camera: missing %s", #sel); } while (0)

// Only the camera is Saguru's business. Anything asked about another kind of device (the microphone,
// above all) gets Apple's own answer, as if Saguru were not there.
static BOOL IsVideo(AVMediaType t) { return !t || [t isEqualToString:AVMediaTypeVideo]; }
static AVCaptureDevice *(*oDefaultDevice)(id, SEL, AVMediaType);
static AVCaptureDevice *DefaultDevice(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? Camera(AVCaptureDevicePositionBack) : oDefaultDevice(s, c, t); }
static AVCaptureDevice *(*oDefaultDevice3)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition);
static AVCaptureDevice *DefaultDevice3(id s, SEL c, AVCaptureDeviceType dt, AVMediaType t, AVCaptureDevicePosition p) {
    if (!IsVideo(t) || [dt isEqualToString:AVCaptureDeviceTypeMicrophone]) return oDefaultDevice3(s, c, dt, t, p);
    return Camera(p);
}
static NSArray *Devices(id s, SEL c) { return @[Camera(AVCaptureDevicePositionBack), Camera(AVCaptureDevicePositionFront)]; }
static NSArray *(*oDevicesWith)(id, SEL, AVMediaType);
static NSArray *DevicesWith(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? Devices(s, c) : oDevicesWith(s, c, t); }
static AVCaptureDevice *(*oDeviceWithID)(id, SEL, NSString *);
static AVCaptureDevice *DeviceWithID(id s, SEL c, NSString *identifier) {
    for (AVCaptureDevice *camera in Devices(s, c)) if ([camera.uniqueID isEqualToString:identifier]) return camera;
    return oDeviceWithID(s, c, identifier);
}
static AVCaptureDevice *Preferred(id s, SEL c) { return Camera(AVCaptureDevicePositionBack); }
static void SetPreferred(id s, SEL c, AVCaptureDevice *device) {}
static AVAuthorizationStatus (*oStatus)(id, SEL, AVMediaType);
static AVAuthorizationStatus Status(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? AVAuthorizationStatusAuthorized : oStatus(s, c, t); }
static void (*oRequest)(id, SEL, AVMediaType, void (^)(BOOL));
static void Request(id s, SEL c, AVMediaType t, void (^done)(BOOL)) {
    if (![t isEqualToString:AVMediaTypeVideo]) { oRequest(s, c, t, done); return; }
    if (done) dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(YES); });
}

// A search remembers what it was asked for, so one for the front camera does not come back with the back one first.
static char kSearchVideo, kSearchSpot;
static id (*oSearch)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition);
static id Search(id s, SEL c, NSArray *types, AVMediaType t, AVCaptureDevicePosition p) {
    id found = oSearch(s, c, types, t, p);
    BOOL cameras = IsVideo(t) && !(types.count && [types isEqualToArray:@[AVCaptureDeviceTypeMicrophone]]);
    if (found) { objc_setAssociatedObject(found, &kSearchVideo, @(cameras), OBJC_ASSOCIATION_RETAIN); objc_setAssociatedObject(found, &kSearchSpot, @(p), OBJC_ASSOCIATION_RETAIN); }
    return found;
}
static NSArray *(*oSearchDevices)(id, SEL);
static NSArray *SearchDevices(id s, SEL c) {
    NSNumber *cameras = objc_getAssociatedObject(s, &kSearchVideo);
    if (cameras && !cameras.boolValue) return oSearchDevices(s, c);
    AVCaptureDevicePosition spot = [objc_getAssociatedObject(s, &kSearchSpot) integerValue];
    return spot == AVCaptureDevicePositionUnspecified ? Devices(s, c) : @[Camera(spot)];
}
static NSArray *SearchSets(id s, SEL c) { return @[]; }

static id (*oInputClass)(id, SEL, AVCaptureDevice *, NSError **);
static id InputClass(id s, SEL c, AVCaptureDevice *d, NSError **e) { if (!IsOurs(d)) return oInputClass(s, c, d, e); SaguruInput *i = Bare(SaguruInput.class); i.fake = d; return i; }
// An init method hands its result over already retained, and takes ownership of the object it was sent to.
// Declared that way so the pretend input is not released once too often (which crashed Swift apps later on).
typedef __attribute__((ns_returns_retained)) id (*InitWithDevice)(__attribute__((ns_consumed)) id, SEL, AVCaptureDevice *, NSError **);
static InitWithDevice oInputInit;
__attribute__((ns_returns_retained)) static id InputInit(__attribute__((ns_consumed)) id s, SEL c, AVCaptureDevice *d, NSError **e) {
    if (!IsOurs(d)) return oInputInit(s, c, d, e);
    SaguruInput *i = Bare(SaguruInput.class); i.fake = d; return i;
}

// The app adds and removes inputs and outputs on its own threads while the feeder reads the same lists, so
// every touch of them, and of the table of sessions, goes through one lock.
static NSMutableArray *List(id session, char *key) { NSMutableArray *a = objc_getAssociatedObject(session, key); if (!a) { a = [NSMutableArray array]; objc_setAssociatedObject(session, key, a, OBJC_ASSOCIATION_RETAIN); [gSessions addObject:session]; } return a; }
static NSArray *Listed(id session, char *key) { @synchronized (gSessions) { return [objc_getAssociatedObject(session, key) copy] ?: @[]; } }
static BOOL CanAdd(id s, SEL c, id x) { return YES; }
static void AddInput(id s, SEL c, id x) { @synchronized (gSessions) { if (x && ![List(s, &kInputs) containsObject:x]) [List(s, &kInputs) addObject:x]; } }
static void AddOutput(id s, SEL c, id x) { @synchronized (gSessions) { if (x && ![List(s, &kOutputs) containsObject:x]) { [List(s, &kOutputs) addObject:x]; objc_setAssociatedObject(x, &kAdded, @YES, OBJC_ASSOCIATION_RETAIN); } } }
static void Remove(id s, SEL c, id x) { @synchronized (gSessions) { [(NSMutableArray *)objc_getAssociatedObject(s, &kInputs) removeObject:x]; }
    @synchronized (gSessions) { [(NSMutableArray *)objc_getAssociatedObject(s, &kOutputs) removeObject:x]; if (x) objc_setAssociatedObject(x, &kAdded, nil, OBJC_ASSOCIATION_RETAIN); } }
// Read-only: a session being destroyed asks for these, and must not be registered again then.
static NSArray *Inputs(id s, SEL c) { return Listed(s, &kInputs); }
static NSArray *Outputs(id s, SEL c) { return Listed(s, &kOutputs); }
/// The picture size each preset stands for on a phone held upright (the sensor's are these, lying down).
/// 4K is answered with 1080p: the Simulator would spend its time scaling.
static void Want(AVCaptureSessionPreset preset) {
    int w = 1080, h = 1920;
    if ([preset isEqual:AVCaptureSessionPresetPhoto]) { w = 1080; h = 1440; }
    else if ([preset isEqual:AVCaptureSessionPreset1280x720] || [preset isEqual:AVCaptureSessionPresetiFrame1280x720]) { w = 720; h = 1280; }
    else if ([preset isEqual:AVCaptureSessionPresetiFrame960x540]) { w = 540; h = 960; }
    else if ([preset isEqual:AVCaptureSessionPreset640x480]) { w = 480; h = 640; }
    else if ([preset isEqual:AVCaptureSessionPresetMedium]) { w = 360; h = 480; }
    else if ([preset isEqual:AVCaptureSessionPreset352x288]) { w = 288; h = 352; }
    else if ([preset isEqual:AVCaptureSessionPresetLow]) { w = 144; h = 192; }
    gWantW = w; gWantH = h;
    // Saguru reads this to frame its picture to the same shape, so nothing the user sees is cut off unasked.
    [[NSString stringWithFormat:@"%d %d", w, h] writeToFile:[gFolder stringByAppendingPathComponent:@"want"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static AVCaptureSessionPreset Preset(id s, SEL c) { return objc_getAssociatedObject(s, &kPreset) ?: AVCaptureSessionPresetHigh; }
static void SetPreset(id s, SEL c, AVCaptureSessionPreset preset) { objc_setAssociatedObject(s, &kPreset, [preset copy], OBJC_ASSOCIATION_RETAIN); Want(preset); }
static void Announce(id session, NSNotificationName name) { dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:name object:session]; }); }
static void Start(id s, SEL c) {
    @synchronized (gSessions) { List(s, &kOutputs); }
    Want(Preset(s, c));
    if ([objc_getAssociatedObject(s, &kRunning) boolValue]) return;
    objc_setAssociatedObject(s, &kRunning, @YES, OBJC_ASSOCIATION_RETAIN);
    NSLog(@"Saguru camera: session started (%d×%d)", gWantW, gWantH);
    Announce(s, AVCaptureSessionDidStartRunningNotification);
}
static void Stop(id s, SEL c) {
    if (![objc_getAssociatedObject(s, &kRunning) boolValue]) return;
    objc_setAssociatedObject(s, &kRunning, @NO, OBJC_ASSOCIATION_RETAIN);
    Announce(s, AVCaptureSessionDidStopRunningNotification);
}
static AVCaptureConnection *OutputConnection(AVCaptureOutput *output, SEL c, AVMediaType type) {
    if (!objc_getAssociatedObject(output, &kAdded)) return nil;
    BOOL meta = [output isKindOfClass:AVCaptureMetadataOutput.class];
    return [type isEqualToString:meta ? AVMediaTypeMetadata : AVMediaTypeVideo] ? ConnectionFor(output) : nil;
}
static NSArray *OutputConnections(AVCaptureOutput *output, SEL c) { return objc_getAssociatedObject(output, &kAdded) ? @[ConnectionFor(output)] : @[]; }
static NSArray *SessionConnections(id s, SEL c) { NSMutableArray *all = [NSMutableArray array]; for (id output in Outputs(s, c)) [all addObject:ConnectionFor(output)]; return all; }
static AVCaptureConnection *(*oLayerConnection)(id, SEL);
static AVCaptureConnection *LayerConnection(id layer, SEL c) { return [gLayers containsObject:layer] ? ConnectionFor(layer) : oLayerConnection(layer, c); }
static BOOL Running(id s, SEL c) { return [objc_getAssociatedObject(s, &kRunning) boolValue]; }
static void Nothing(id s, SEL c) {}
static BOOL Yes1(id s, SEL c, id x) { return YES; }
static void AddNothing(id s, SEL c, id x) {}

static NSArray *MetaAvailable(id s, SEL c) { return @[AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code, AVMetadataObjectTypeEAN8Code, AVMetadataObjectTypeCode128Code, AVMetadataObjectTypePDF417Code, AVMetadataObjectTypeAztecCode, AVMetadataObjectTypeDataMatrixCode]; }
static void MetaSet(id s, SEL c, NSArray *types) { objc_setAssociatedObject(s, &kTypes, [types copy], OBJC_ASSOCIATION_RETAIN); }
static NSArray *MetaGet(id s, SEL c) { return objc_getAssociatedObject(s, &kTypes) ?: @[]; }

static void (*oSetSession)(id, SEL, AVCaptureSession *);
static void SetSession(id s, SEL c, AVCaptureSession *session) { [gLayers addObject:s]; oSetSession(s, c, session); }
typedef __attribute__((ns_returns_retained)) id (*InitWithSession)(__attribute__((ns_consumed)) id, SEL, AVCaptureSession *);
static InitWithSession oLayerInit;
__attribute__((ns_returns_retained)) static id LayerInit(__attribute__((ns_consumed)) id s, SEL c, AVCaptureSession *session) {
    id layer = oLayerInit(s, c, session); if (layer) [gLayers addObject:layer]; return layer;
}
static id Transformed(AVCaptureVideoPreviewLayer *layer, SEL c, AVMetadataObject *object) {
    if (![object isKindOfClass:SaguruCode.class] || !gPixels) return object;
    // Where the normalised box falls in the layer, for the gravity in use.
    CGSize image = CGSizeMake(CVPixelBufferGetWidth(gPixels), CVPixelBufferGetHeight(gPixels)), view = layer.bounds.size;
    BOOL fill = [layer.videoGravity isEqual:AVLayerVideoGravityResizeAspectFill];
    CGFloat scale = fill ? MAX(view.width / image.width, view.height / image.height) : MIN(view.width / image.width, view.height / image.height);
    CGFloat dx = (view.width - image.width * scale) / 2, dy = (view.height - image.height * scale) / 2;
    CGRect b = ((SaguruCode *)object).box;
    SaguruCode *moved = Bare(SaguruCode.class); moved.text = ((SaguruCode *)object).text;
    moved.box = CGRectMake(dx + b.origin.x * image.width * scale, dy + b.origin.y * image.height * scale, b.size.width * image.width * scale, b.size.height * image.height * scale);
    return moved;
}

// Where a point of the preview falls on the camera, and back. The camera's own coordinates run 0 to 1 over
// the sensor lying on its side: a phone held upright has the sensor's (0,0) at the top right of the picture.
static CGRect PictureRect(AVCaptureVideoPreviewLayer *layer) {
    CGSize view = layer.bounds.size, image = gPixels ? CGSizeMake(CVPixelBufferGetWidth(gPixels), CVPixelBufferGetHeight(gPixels)) : CGSizeMake(1080, 1920);
    if (view.width <= 0 || view.height <= 0) return CGRectMake(0, 0, 1, 1);
    NSString *g = layer.videoGravity;
    if ([g isEqual:AVLayerVideoGravityResize]) return CGRectMake(0, 0, view.width, view.height);
    CGFloat scale = [g isEqual:AVLayerVideoGravityResizeAspectFill] ? MAX(view.width / image.width, view.height / image.height) : MIN(view.width / image.width, view.height / image.height);
    return CGRectMake((view.width - image.width * scale) / 2, (view.height - image.height * scale) / 2, image.width * scale, image.height * scale);
}
static CGPoint DevicePoint(AVCaptureVideoPreviewLayer *layer, SEL c, CGPoint p) {
    CGRect r = PictureRect(layer); CGFloat u = (p.x - r.origin.x) / r.size.width, v = (p.y - r.origin.y) / r.size.height;
    return CGPointMake(v, 1 - u);
}
static CGPoint LayerPoint(AVCaptureVideoPreviewLayer *layer, SEL c, CGPoint p) {
    CGRect r = PictureRect(layer);
    return CGPointMake(r.origin.x + (1 - p.y) * r.size.width, r.origin.y + p.x * r.size.height);
}
static CGRect DeviceRect(AVCaptureVideoPreviewLayer *layer, SEL c, CGRect rect) {
    CGPoint a = DevicePoint(layer, c, CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect))), b = DevicePoint(layer, c, CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect)));
    return CGRectMake(a.x, a.y, b.x - a.x, b.y - a.y);
}
static CGRect LayerRect(AVCaptureVideoPreviewLayer *layer, SEL c, CGRect rect) {
    CGPoint a = LayerPoint(layer, c, CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect))), b = LayerPoint(layer, c, CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect)));
    return CGRectMake(a.x, a.y, b.x - a.x, b.y - a.y);
}

static CMVideoDimensions PhotoSize(id s, SEL c);

static NSData *CopyJPEG(void) {
    if (!gPixels) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSData *jpeg = [gContext JPEGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:gPixels] colorSpace:space options:@{}];
    CGColorSpaceRelease(space);
    return jpeg;
}

/// A JPEG the way the older photo calls hand it over: inside a sample buffer.
static CMSampleBufferRef CopyJPEGSample(NSData *jpeg, int32_t width, int32_t height) {
    if (!jpeg.length) return NULL;
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, jpeg.length, NULL, NULL, 0, jpeg.length, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr || !block) return NULL;
    CMBlockBufferReplaceDataBytes(jpeg.bytes, block, 0, jpeg.length);
    CMVideoFormatDescriptionRef format = NULL; CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_JPEG, width, height, NULL, &format);
    CMSampleBufferRef sample = NULL; size_t size = jpeg.length;
    CMSampleTimingInfo timing = { kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid };
    CMSampleBufferCreateReady(NULL, block, format, 1, 1, &timing, 1, &size, &sample);
    if (format) CFRelease(format);
    CFRelease(block);
    return sample;
}

/// Takes the photo and tells the delegate every step a real capture goes through, in the same order:
/// some apps wait for the last one before moving on. A delegate written for the photo call of iOS 10
/// gets its photo the way that call gave it.
static void Capture(AVCapturePhotoOutput *output, SEL c, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    int64_t number = settings.uniqueID;
    dispatch_async(gFeed, ^{
        SaguruResolved *resolved = Bare(SaguruResolved.class); resolved.number = number;
        SaguruPhoto *photo = Bare(SaguruPhoto.class); photo.resolved = resolved;
        if (gPixels) resolved.size = (CMVideoDimensions){(int32_t)CVPixelBufferGetWidth(gPixels), (int32_t)CVPixelBufferGetHeight(gPixels)};
        photo.jpeg = CopyJPEG();
        NSError *failure = photo.jpeg ? nil : [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorUnknown userInfo:@{NSLocalizedDescriptionKey: @"Saguru has no picture to give yet."}];
        if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) [delegate captureOutput:output willBeginCaptureForResolvedSettings:resolved];
        if ([delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) [delegate captureOutput:output willCapturePhotoForResolvedSettings:resolved];
        if ([delegate respondsToSelector:@selector(captureOutput:didCapturePhotoForResolvedSettings:)]) [delegate captureOutput:output didCapturePhotoForResolvedSettings:resolved];
        SEL old = NSSelectorFromString(@"captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) [delegate captureOutput:output didFinishProcessingPhoto:photo error:failure];
        else if ([delegate respondsToSelector:old]) {
            CMSampleBufferRef sample = CopyJPEGSample(photo.jpeg, resolved.size.width, resolved.size.height);
            ((void (*)(id, SEL, id, CMSampleBufferRef, CMSampleBufferRef, id, id, NSError *))objc_msgSend)(delegate, old, output, sample, NULL, resolved, nil, failure);
            if (sample) CFRelease(sample);
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) [delegate captureOutput:output didFinishCaptureForResolvedSettings:resolved error:failure];
    });
}
static void Prepare(id output, SEL c, NSArray *settings, void (^done)(BOOL, NSError *)) { if (done) dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(YES, nil); }); }
static NSArray *PreviewFormats(id settings, SEL c) { return @[@(kCVPixelFormatType_32BGRA)]; }
static NSArray *ThumbnailCodecs(id settings, SEL c) { return @[AVVideoCodecTypeJPEG]; }

/// The still-image call that came before AVCapturePhotoOutput. Apps that never moved on still use it.
static void CaptureStill(id output, SEL c, AVCaptureConnection *connection, void (^done)(CMSampleBufferRef, NSError *)) {
    if (!done) return;
    dispatch_async(gFeed, ^{
        NSData *jpeg = CopyJPEG();
        CMSampleBufferRef sample = jpeg ? CopyJPEGSample(jpeg, (int32_t)CVPixelBufferGetWidth(gPixels), (int32_t)CVPixelBufferGetHeight(gPixels)) : NULL;
        done(sample, sample ? nil : [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorUnknown userInfo:@{NSLocalizedDescriptionKey: @"Saguru has no picture to give yet."}]);
        if (sample) CFRelease(sample);
    });
}

/// Saguru records no video. Asking for it used to raise, with no camera wired to the output; now the
/// recording ends at once with an error that says so, the way a recording that cannot start does.
static void Record(AVCaptureFileOutput *output, SEL c, NSURL *file, id<AVCaptureFileOutputRecordingDelegate> delegate) {
    NSLog(@"Saguru camera: video recording was asked for; Saguru does not record, and says so to the delegate");
    NSError *failure = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorSessionNotRunning userInfo:@{NSLocalizedDescriptionKey: @"La cámara de Saguru no graba video.", AVErrorRecordingSuccessfullyFinishedKey: @NO}];
    dispatch_async(dispatch_get_main_queue(), ^{ [delegate captureOutput:output didFinishRecordingToOutputFileAtURL:file fromConnections:@[] error:failure]; });
}
static BOOL No0(id s, SEL c) { return NO; }

/// The photo output's settings are checked against a real camera's formats; without one, setting them
/// raises. They are simply remembered instead.
static char kPhotoSize, kPhotoQuality, kPhotoHigh;
static void SetPhotoSize(id s, SEL c, CMVideoDimensions d) { objc_setAssociatedObject(s, &kPhotoSize, [NSValue valueWithBytes:&d objCType:@encode(CMVideoDimensions)], OBJC_ASSOCIATION_RETAIN); }
static CMVideoDimensions PhotoSize(id s, SEL c) { CMVideoDimensions d = {1920, 1440}; [objc_getAssociatedObject(s, &kPhotoSize) getValue:&d]; return d; }
static void SetPhotoQuality(id s, SEL c, NSInteger q) { objc_setAssociatedObject(s, &kPhotoQuality, @(q), OBJC_ASSOCIATION_RETAIN); }
static NSInteger PhotoQuality(id s, SEL c) { NSNumber *q = objc_getAssociatedObject(s, &kPhotoQuality); return q ? q.integerValue : AVCapturePhotoQualityPrioritizationBalanced; }
static void SetPhotoHigh(id s, SEL c, BOOL b) { objc_setAssociatedObject(s, &kPhotoHigh, @(b), OBJC_ASSOCIATION_RETAIN); }
static BOOL PhotoHigh(id s, SEL c) { return [objc_getAssociatedObject(s, &kPhotoHigh) boolValue]; }
static NSArray *PhotoCodecs(id s, SEL c) { return @[AVVideoCodecTypeJPEG]; }
static NSArray *PhotoPixelFormats(id s, SEL c) { return @[@(kCVPixelFormatType_32BGRA)]; }
static NSArray *PhotoFlashModes(id s, SEL c) { return @[@(AVCaptureFlashModeOff)]; }

// MARK: Apple's camera screen (UIImagePickerController with the camera as source)

/// The Simulator cannot show Apple's camera screen, so a plain one takes its place: the live picture,
/// a shutter and a cancel button. The app gets the photo through the picker's own delegate, as always.
@interface SaguruShutterController : UIViewController
@property (nonatomic, weak) UIImagePickerController *picker;
@property (nonatomic, strong) CALayer *screen;
@end

static CVPixelBufferRef CopyCurrentPixels(void) {
    __block CVPixelBufferRef pixels = NULL;
    dispatch_sync(gFeed, ^{ if (gPixels) pixels = CVPixelBufferRetain(gPixels); });
    return pixels;
}

@implementation SaguruShutterController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.screen = [CALayer layer];
    self.screen.contentsGravity = kCAGravityResizeAspect;
    [self.view.layer addSublayer:self.screen];
    // Laid over the picker, this screen is not told when it appears, so it refreshes on a timer of its own
    // that ends with it.
    __weak typeof(self) weak = self;
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
        typeof(self) me = weak;
        if (!me) { [timer invalidate]; return; }
        [me refresh];
    }];
    UIButton *shutter = [UIButton buttonWithType:UIButtonTypeCustom];
    shutter.backgroundColor = UIColor.whiteColor; shutter.layer.cornerRadius = 34;
    shutter.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor; shutter.layer.borderWidth = 4;
    shutter.accessibilityLabel = @"Tomar foto";
    [shutter addTarget:self action:@selector(shoot) forControlEvents:UIControlEventTouchUpInside];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancelar" forState:UIControlStateNormal]; [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:18];
    [cancel addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[shutter, cancel]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [shutter.widthAnchor constraintEqualToConstant:68], [shutter.heightAnchor constraintEqualToConstant:68],
        [shutter.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [shutter.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-24],
        [cancel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22], [cancel.centerYAnchor constraintEqualToAnchor:shutter.centerYAnchor]]];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect area = self.view.bounds; area.size.height -= 130 + self.view.safeAreaInsets.bottom;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.screen.frame = area; [CATransaction commit];
}
- (void)refresh {
    CVPixelBufferRef pixels = CopyCurrentPixels();
    if (!pixels) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.screen.contents = (__bridge id)CVPixelBufferGetIOSurface(pixels);
    [CATransaction commit];
    CVPixelBufferRelease(pixels);
}
- (void)shoot {
    UIImagePickerController *picker = self.picker;
    id<UIImagePickerControllerDelegate, UINavigationControllerDelegate> delegate = picker.delegate;
    CVPixelBufferRef pixels = CopyCurrentPixels();
    UIImage *photo = nil;
    if (pixels) {
        CIImage *picture = [CIImage imageWithCVPixelBuffer:pixels];
        CGImageRef image = [gContext createCGImage:picture fromRect:picture.extent];
        if (image) { photo = [UIImage imageWithCGImage:image]; CGImageRelease(image); }
        CVPixelBufferRelease(pixels);
    }
    if (photo && [delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
        [delegate imagePickerController:picker didFinishPickingMediaWithInfo:@{UIImagePickerControllerOriginalImage: photo, UIImagePickerControllerMediaType: @"public.image"}];
    } else {
        [self cancel];
    }
}
- (void)cancel {
    UIImagePickerController *picker = self.picker;
    id<UIImagePickerControllerDelegate, UINavigationControllerDelegate> delegate = picker.delegate;
    if ([delegate respondsToSelector:@selector(imagePickerControllerDidCancel:)]) [delegate imagePickerControllerDidCancel:picker];
    else [picker dismissViewControllerAnimated:YES completion:nil];
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

static BOOL (*oSourceAvailable)(id, SEL, UIImagePickerControllerSourceType);
static BOOL SourceAvailable(id s, SEL c, UIImagePickerControllerSourceType type) { return type == UIImagePickerControllerSourceTypeCamera ? YES : oSourceAvailable(s, c, type); }
static BOOL CameraDeviceAvailable(id s, SEL c, UIImagePickerControllerCameraDevice device) { return YES; }
static NSArray *(*oMediaTypes)(id, SEL, UIImagePickerControllerSourceType);
static NSArray *MediaTypes(id s, SEL c, UIImagePickerControllerSourceType type) { return type == UIImagePickerControllerSourceTypeCamera ? @[@"public.image"] : oMediaTypes(s, c, type); }
static void (*oSetSource)(id, SEL, UIImagePickerControllerSourceType);
static void SetSource(UIImagePickerController *picker, SEL c, UIImagePickerControllerSourceType type) {
    BOOL camera = type == UIImagePickerControllerSourceTypeCamera;
    objc_setAssociatedObject(picker, &kPickerCamera, @(camera), OBJC_ASSOCIATION_RETAIN);
    // Asking the real picker for the camera throws in the Simulator; it is left on its default source.
    if (!camera) oSetSource(picker, c, type);
}
static UIImagePickerControllerSourceType (*oGetSource)(id, SEL);
static UIImagePickerControllerSourceType GetSource(UIImagePickerController *picker, SEL c) {
    return [objc_getAssociatedObject(picker, &kPickerCamera) boolValue] ? UIImagePickerControllerSourceTypeCamera : oGetSource(picker, c);
}
/// Puts the stand-in screen over whatever the picker shows. The picker builds its own (photo library)
/// content as it appears, so the cover is laid on top rather than swapped in, and kept in front.
static void Cover(UIImagePickerController *picker) {
    if (![objc_getAssociatedObject(picker, &kPickerCamera) boolValue]) return;
    SaguruShutterController *screen = objc_getAssociatedObject(picker, &kPickerShown);
    if (!screen) {
        screen = [SaguruShutterController new];
        screen.picker = picker;
        objc_setAssociatedObject(picker, &kPickerShown, screen, OBJC_ASSOCIATION_RETAIN);
        [picker addChildViewController:screen];
        screen.view.frame = picker.view.bounds;
        screen.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [picker.view addSubview:screen.view];
        [screen didMoveToParentViewController:picker];
    }
    [picker.view bringSubviewToFront:screen.view];
}

// viewWillAppear: and viewDidAppear: are replaced on the picker if it has its own, and added if it only inherits them.
static void (*oPickerWillAppear)(id, SEL, BOOL);
static void (*oPickerDidAppear)(id, SEL, BOOL);
static void CallUp(void (*original)(id, SEL, BOOL), UIImagePickerController *picker, SEL c, BOOL animated) {
    if (original) original(picker, c, animated);
    else { struct objc_super up = { picker, class_getSuperclass(UIImagePickerController.class) }; ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&up, c, animated); }
}
static void PickerWillAppear(UIImagePickerController *picker, SEL c, BOOL animated) { CallUp(oPickerWillAppear, picker, c, animated); Cover(picker); }
static void PickerDidAppear(UIImagePickerController *picker, SEL c, BOOL animated) {
    CallUp(oPickerDidAppear, picker, c, animated);
    Cover(picker);
    // Its content may arrive a moment later, from another process.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Cover(picker); });
}

// MARK: The safety net

/// Says once, in the app's log, that a method without a stand-in was called.
static void Note(id object, SEL selector) {
    static NSMutableSet *said; static dispatch_once_t once; dispatch_once(&once, ^{ said = [NSMutableSet set]; });
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", class_getSuperclass(object_getClass(object)), NSStringFromSelector(selector)];
    @synchronized (said) { if ([said containsObject:name]) return; [said addObject:name]; }
    NSLog(@"Saguru camera: %@ has no stand-in; answered with nothing", name);
}
static id NetNothing(id s, SEL c) { Note(s, c); return nil; }
static double NetDouble(id s, SEL c) { Note(s, c); return 0; }
static float NetFloat(id s, SEL c) { Note(s, c); return 0; }
// Methods that return a structure, by the shape of what they return: the compiler returns each shape its
// own way (in registers, or through a pointer the caller passes), so each needs a stand-in of that shape.
typedef struct { double a, b; } Two;      typedef struct { double a, b, c, d; } Four;      typedef struct { double a[6]; } Six;
typedef struct { float a, b; } TwoF;      typedef struct { float a, b, c; } ThreeF;        typedef struct { float a, b, c, d; } FourF;
typedef struct { int32_t a, b; } Pair;    typedef struct { int64_t a, b; } Wide;
static Two NetTwo(id s, SEL c) { Note(s, c); return (Two){0}; }
static Four NetFour(id s, SEL c) { Note(s, c); return (Four){0}; }
static Six NetSix(id s, SEL c) { Note(s, c); return (Six){{0}}; }
static TwoF NetTwoF(id s, SEL c) { Note(s, c); return (TwoF){0}; }
static ThreeF NetThreeF(id s, SEL c) { Note(s, c); return (ThreeF){0}; }
static FourF NetFourF(id s, SEL c) { Note(s, c); return (FourF){0}; }
static Pair NetPair(id s, SEL c) { Note(s, c); return (Pair){0}; }
static Wide NetWide(id s, SEL c) { Note(s, c); return (Wide){0}; }
static CMTime NetTime(id s, SEL c) { Note(s, c); return kCMTimeInvalid; }
static CMTimeRange NetRange(id s, SEL c) { Note(s, c); return kCMTimeRangeInvalid; }
/// The stand-in for a structure with this encoding, or NULL for a shape not listed here.
static IMP NetShape(const char *type) {
    static NSDictionary<NSString *, NSValue *> *shapes; static dispatch_once_t once;
    dispatch_once(&once, ^{ shapes = @{
        @(@encode(CGPoint)): [NSValue valueWithPointer:NetTwo], @(@encode(CGSize)): [NSValue valueWithPointer:NetTwo],
        @(@encode(CGRect)): [NSValue valueWithPointer:NetFour], @(@encode(CGAffineTransform)): [NSValue valueWithPointer:NetSix],
        @(@encode(CMTime)): [NSValue valueWithPointer:NetTime], @(@encode(CMTimeRange)): [NSValue valueWithPointer:NetRange],
        @(@encode(CMVideoDimensions)): [NSValue valueWithPointer:NetPair],
        @(@encode(AVCaptureWhiteBalanceGains)): [NSValue valueWithPointer:NetThreeF],
        @(@encode(AVCaptureWhiteBalanceChromaticityValues)): [NSValue valueWithPointer:NetTwoF],
        @(@encode(AVCaptureWhiteBalanceTemperatureAndTintValues)): [NSValue valueWithPointer:NetTwoF],
    }; });
    return (IMP)shapes[@(type)].pointerValue;
}
/// Gives a pretend class a harmless answer for every method of Apple's class it does not answer itself.
/// Apple's would read inner state the pretend object never had. A method returning a structure gets a
/// stand-in when its shape is one of those listed above; any other is left alone.
static void Net(Class ours, Class theirs) {
    for (Class from = theirs; from && from != NSObject.class; from = class_getSuperclass(from)) {
        unsigned count = 0; Method *list = class_copyMethodList(from, &count);
        for (unsigned i = 0; i < count; i++) {
            const char *name = sel_getName(method_getName(list[i]));
            if (!strncmp(name, "init", 4) || !strcmp(name, "dealloc") || name[0] == '.' || !strcmp(name, "description") || !strcmp(name, "debugDescription")
                || !strcmp(name, "isEqual:") || !strcmp(name, "hash") || !strncmp(name, "observeValueForKeyPath", 22)) continue;
            char type[256]; method_getReturnType(list[i], type, sizeof type);
            const char *t = type; while (*t && strchr("rnNoORV", *t)) t++;
            IMP answer = *t == 'd' ? (IMP)NetDouble : *t == 'f' ? (IMP)NetFloat : (*t && strchr("v@#:BcCsSiIlLqQ*^", *t)) ? (IMP)NetNothing : *t == '{' ? NetShape(t) : NULL;
            if (answer) class_addMethod(ours, method_getName(list[i]), answer, method_getTypeEncoding(list[i]));   // fails, rightly, where ours answers already
        }
        free(list);
    }
}

/// How a pretend object goes away. Written `- (void)dealloc {}`, the compiler still calls Apple's dealloc
/// after it, and that one reads inner state the object never had: an app crashed with a bad memory access
/// the moment it let go of its preview layer. This releases what the object holds and frees it, and
/// Apple's dealloc is never reached.
static void BareDealloc(__unsafe_unretained id object, SEL command) {
    if ([object respondsToSelector:@selector(saguruCleanUp)]) [object performSelector:@selector(saguruCleanUp)];
    // The runtime's own way of freeing an instance; the compiler hides it from code it manages memory for.
    static void *(*dispose)(void *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dispose = dlsym(RTLD_DEFAULT, "object_dispose"); });
    if (dispose) dispose((__bridge void *)object);
}
static void Mortal(Class ours) { class_replaceMethod(ours, sel_registerName("dealloc"), (IMP)BareDealloc, "v@:"); }

__attribute__((constructor)) static void SaguruCameraLoad(void) {
    const char *folder = getenv("SAGURU_CAM_FOLDER");
    if (!folder) return;
    gFolder = @(folder);
    gFramePath = [gFolder stringByAppendingPathComponent:@"frame.bgra"];
    Net(SaguruCamera.class, AVCaptureDevice.class); Net(SaguruFormat.class, AVCaptureDeviceFormat.class);
    Net(SaguruInput.class, AVCaptureDeviceInput.class); Net(SaguruConnection.class, AVCaptureConnection.class);
    Net(SaguruPhoto.class, AVCapturePhoto.class); Net(SaguruResolved.class, AVCaptureResolvedPhotoSettings.class);
    Net(SaguruCode.class, AVMetadataMachineReadableCodeObject.class);
    for (Class bare in @[SaguruCamera.class, SaguruFormat.class, SaguruInput.class, SaguruConnection.class, SaguruPhoto.class, SaguruResolved.class, SaguruCode.class]) Mortal(bare);
    gContext = [CIContext context];
    gDetect = dispatch_queue_create("dev.saguru.camera.codes", DISPATCH_QUEUE_SERIAL);
    gSessions = [NSHashTable weakObjectsHashTable]; gLayers = [NSHashTable weakObjectsHashTable];
    void *unused;
    Class dev = object_getClass(AVCaptureDevice.class);
    SWAP(dev, defaultDeviceWithMediaType:, DefaultDevice, oDefaultDevice);
    SWAP(dev, defaultDeviceWithDeviceType:mediaType:position:, DefaultDevice3, oDefaultDevice3);
    SWAP(dev, devices, Devices, unused);
    SWAP(dev, devicesWithMediaType:, DevicesWith, oDevicesWith);
    SWAP(dev, deviceWithUniqueID:, DeviceWithID, oDeviceWithID);
    SWAP(dev, userPreferredCamera, Preferred, unused); SWAP(dev, systemPreferredCamera, Preferred, unused); SWAP(dev, setUserPreferredCamera:, SetPreferred, unused);
    SWAP(dev, authorizationStatusForMediaType:, Status, oStatus);
    SWAP(dev, requestAccessForMediaType:completionHandler:, Request, oRequest);
    SWAP(object_getClass(AVCaptureDeviceDiscoverySession.class), discoverySessionWithDeviceTypes:mediaType:position:, Search, oSearch);
    SWAP(AVCaptureDeviceDiscoverySession.class, devices, SearchDevices, oSearchDevices);
    SWAP(AVCaptureDeviceDiscoverySession.class, supportedMultiCamDeviceSets, SearchSets, unused);
    SWAP(object_getClass(AVCaptureDeviceInput.class), deviceInputWithDevice:error:, InputClass, oInputClass);
    SWAP(AVCaptureDeviceInput.class, initWithDevice:error:, InputInit, oInputInit);
    Class ses = AVCaptureSession.class;
    SWAP(ses, canAddInput:, CanAdd, unused); SWAP(ses, canAddOutput:, CanAdd, unused);
    SWAP(ses, addInput:, AddInput, unused); SWAP(ses, addOutput:, AddOutput, unused);
    SWAP(ses, removeInput:, Remove, unused); SWAP(ses, removeOutput:, Remove, unused);
    // Sessions wired by hand: the parts are taken the same way, and the wires themselves are not needed.
    SWAP(ses, addInputWithNoConnections:, AddInput, unused); SWAP(ses, addOutputWithNoConnections:, AddOutput, unused);
    SWAP(ses, canAddConnection:, Yes1, unused); SWAP(ses, addConnection:, AddNothing, unused); SWAP(ses, removeConnection:, AddNothing, unused);
    SWAP(ses, inputs, Inputs, unused); SWAP(ses, outputs, Outputs, unused);
    SWAP(ses, startRunning, Start, unused); SWAP(ses, stopRunning, Stop, unused); SWAP(ses, isRunning, Running, unused);
    SWAP(ses, beginConfiguration, Nothing, unused); SWAP(ses, commitConfiguration, Nothing, unused);
    SWAP(ses, canSetSessionPreset:, Yes1, unused); SWAP(ses, sessionPreset, Preset, unused); SWAP(ses, setSessionPreset:, SetPreset, unused);
    SWAP(ses, connections, SessionConnections, unused);
    SWAP(AVCaptureOutput.class, connectionWithMediaType:, OutputConnection, unused); SWAP(AVCaptureOutput.class, connections, OutputConnections, unused);
    Class meta = AVCaptureMetadataOutput.class;
    SWAP(meta, availableMetadataObjectTypes, MetaAvailable, unused); SWAP(meta, setMetadataObjectTypes:, MetaSet, unused); SWAP(meta, metadataObjectTypes, MetaGet, unused);
    Class layer = AVCaptureVideoPreviewLayer.class;
    SWAP(layer, setSession:, SetSession, oSetSession); SWAP(layer, initWithSession:, LayerInit, oLayerInit);
    SWAP(layer, transformedMetadataObjectForMetadataObject:, Transformed, unused);
    SWAP(layer, connection, LayerConnection, oLayerConnection);
    Class photo = AVCapturePhotoOutput.class;
    SWAP(photo, capturePhotoWithSettings:delegate:, Capture, unused);
    SWAP(photo, setMaxPhotoDimensions:, SetPhotoSize, unused); SWAP(photo, maxPhotoDimensions, PhotoSize, unused);
    SWAP(photo, setMaxPhotoQualityPrioritization:, SetPhotoQuality, unused); SWAP(photo, maxPhotoQualityPrioritization, PhotoQuality, unused);
    SWAP(photo, setHighResolutionCaptureEnabled:, SetPhotoHigh, unused); SWAP(photo, isHighResolutionCaptureEnabled, PhotoHigh, unused);
    SWAP(photo, availablePhotoCodecTypes, PhotoCodecs, unused); SWAP(photo, availablePhotoPixelFormatTypes, PhotoPixelFormats, unused);
    SWAP(photo, supportedFlashModes, PhotoFlashModes, unused);
    SWAP(photo, setPreparedPhotoSettingsArray:completionHandler:, Prepare, unused);
    SWAP(AVCapturePhotoSettings.class, availablePreviewPhotoPixelFormatTypes, PreviewFormats, unused);
    SWAP(AVCapturePhotoSettings.class, availableEmbeddedThumbnailPhotoCodecTypes, ThumbnailCodecs, unused);
    Class still = NSClassFromString(@"AVCaptureStillImageOutput");
    if (still) { SWAP(still, captureStillImageAsynchronouslyFromConnection:completionHandler:, CaptureStill, unused); }
    Class movie = AVCaptureMovieFileOutput.class;
    SWAP(movie, startRecordingToOutputFileURL:recordingDelegate:, Record, unused); SWAP(movie, stopRecording, Nothing, unused); SWAP(movie, isRecording, No0, unused);
    SWAP(layer, captureDevicePointOfInterestForPoint:, DevicePoint, unused); SWAP(layer, pointForCaptureDevicePointOfInterest:, LayerPoint, unused);
    SWAP(layer, metadataOutputRectOfInterestForRect:, DeviceRect, unused); SWAP(layer, rectForMetadataOutputRectOfInterest:, LayerRect, unused);
    Class picker = UIImagePickerController.class, pickerMeta = object_getClass(picker);
    SWAP(pickerMeta, isSourceTypeAvailable:, SourceAvailable, oSourceAvailable);
    SWAP(pickerMeta, isCameraDeviceAvailable:, CameraDeviceAvailable, unused);
    SWAP(pickerMeta, availableMediaTypesForSourceType:, MediaTypes, oMediaTypes);
    SWAP(picker, setSourceType:, SetSource, oSetSource);
    SWAP(picker, sourceType, GetSource, oGetSource);
    if (!class_addMethod(picker, @selector(viewWillAppear:), (IMP)PickerWillAppear, "v@:B"))
        oPickerWillAppear = (void *)method_setImplementation(class_getInstanceMethod(picker, @selector(viewWillAppear:)), (IMP)PickerWillAppear);
    if (!class_addMethod(picker, @selector(viewDidAppear:), (IMP)PickerDidAppear, "v@:B"))
        oPickerDidAppear = (void *)method_setImplementation(class_getInstanceMethod(picker, @selector(viewDidAppear:)), (IMP)PickerDidAppear);
    gFeed = dispatch_queue_create("dev.saguru.camera", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gFeed);
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{ Tick(); });
    dispatch_resume(gTimer);
}
