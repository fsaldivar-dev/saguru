// SaguruCamera: the part of Saguru's agent that gives an app in the iOS Simulator a camera.
// The Simulator has none, so the app is handed a pretend one. Its pictures come from Saguru on the Mac
// (an image, the Mac's camera, an iPhone used as a camera) through a file both sides map into memory:
//   frame.bgra   64-byte header (magic, sequence, width, height, bytes per row) followed by BGRA pixels.
// The sequence is odd while Saguru is writing a frame, so a half-written one is never used.
//
// What is covered: finding the camera, permission, AVCaptureSession with video frames, the preview layer,
// machine-readable codes (QR) and still photos. Apple's own camera screens are not.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <fcntl.h>

static NSString *gFramePath;
static const uint8_t *gMap;
static size_t gMapSize;
static uint32_t gLastSequence;
static CVPixelBufferRef gPixels;
static NSArray<NSDictionary *> *gCodes;   // payload + normalized box (top-left origin)
static BOOL gDetecting;
static NSHashTable *gSessions, *gLayers;
static dispatch_queue_t gFeed, gDetect;
static dispatch_source_t gTimer;
static CIContext *gContext;
static char kInputs, kOutputs, kRunning, kTypes, kSub;

// MARK: Pretend objects (never initialised the normal way: created bare and answered by these overrides)

@interface SaguruCamera : AVCaptureDevice @end
@implementation SaguruCamera
- (NSString *)uniqueID { return @"dev.saguru.camera"; }
- (NSString *)modelID { return @"Saguru"; }
- (NSString *)localizedName { return @"Cámara de Saguru"; }
- (AVCaptureDevicePosition)position { return AVCaptureDevicePositionBack; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)hasMediaType:(AVMediaType)type { return [type isEqualToString:AVMediaTypeVideo]; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)lockForConfiguration:(NSError **)error { return YES; }
- (void)unlockForConfiguration {}
- (NSArray *)formats { return @[]; }
- (id)activeFormat { return nil; }
- (BOOL)hasTorch { return NO; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)m { return NO; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)m { return NO; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)m { return NO; }
- (BOOL)isFocusPointOfInterestSupported { return NO; }
- (BOOL)isExposurePointOfInterestSupported { return NO; }
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)p { return YES; }
- (CGFloat)videoZoomFactor { return 1; }
- (CGFloat)minAvailableVideoZoomFactor { return 1; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1; }
- (void)dealloc {}
@end

@interface SaguruInput : AVCaptureDeviceInput @property (nonatomic, strong) AVCaptureDevice *fake; @end
@implementation SaguruInput
- (AVCaptureDevice *)device { return self.fake; }
- (NSArray *)ports { return @[]; }
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

@interface SaguruPhoto : AVCapturePhoto @property (nonatomic, strong) NSData *jpeg; @end
@implementation SaguruPhoto
- (NSData *)fileDataRepresentation { return self.jpeg; }
- (CVPixelBufferRef)pixelBuffer { return gPixels; }
- (NSDictionary *)metadata { return @{}; }
- (NSInteger)photoCount { return 1; }
- (BOOL)isRawPhoto { return NO; }
- (CMTime)timestamp { return CMClockGetTime(CMClockGetHostTimeClock()); }
@end

static id Bare(Class c) { return class_createInstance(c, 0); }
static AVCaptureDevice *Camera(void) { static AVCaptureDevice *d; static dispatch_once_t o; dispatch_once(&o, ^{ d = Bare(SaguruCamera.class); }); return d; }

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
    if (gPixels) CVPixelBufferRelease(gPixels);
    gPixels = pixels;
    gLastSequence = before;
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

static void Tick(void) {
    ReadFrame();
    if (!gPixels) return;
    static NSInteger count; count++;
    if (count % 12 == 0) FindCodes();
    CMSampleTimingInfo timing = { CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid };
    CMVideoFormatDescriptionRef format = NULL; CMVideoFormatDescriptionCreateForImageBuffer(NULL, gPixels, &format);
    CMSampleBufferRef sample = NULL; CMSampleBufferCreateReadyWithImageBuffer(NULL, gPixels, format, &timing, &sample);
    if (format) CFRelease(format);
    for (AVCaptureSession *session in gSessions.allObjects) {
        if (![objc_getAssociatedObject(session, &kRunning) boolValue]) continue;
        for (AVCaptureOutput *output in objc_getAssociatedObject(session, &kOutputs)) {
            if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) {
                AVCaptureVideoDataOutput *video = (id)output; id delegate = video.sampleBufferDelegate;
                if (!delegate || !sample) continue;
                CFRetain(sample);
                dispatch_async(video.sampleBufferCallbackQueue ?: dispatch_get_main_queue(), ^{
                    [delegate captureOutput:video didOutputSampleBuffer:sample fromConnection:(id)nil]; CFRelease(sample); });
            } else if ([output isKindOfClass:AVCaptureMetadataOutput.class] && count % 10 == 0 && gCodes.count) {
                AVCaptureMetadataOutput *meta = (id)output; id delegate = meta.metadataObjectsDelegate;
                NSArray *types = objc_getAssociatedObject(meta, &kTypes);
                if (!delegate || ![types containsObject:AVMetadataObjectTypeQRCode]) continue;
                NSMutableArray *found = [NSMutableArray array];
                for (NSDictionary *code in gCodes) { SaguruCode *c = Bare(SaguruCode.class); c.text = code[@"text"]; c.box = [code[@"box"] CGRectValue]; [found addObject:c]; }
                dispatch_async(meta.metadataObjectsCallbackQueue ?: dispatch_get_main_queue(), ^{ [delegate captureOutput:meta didOutputMetadataObjects:found fromConnection:(id)nil]; });
            }
        }
    }
    if (sample) CFRelease(sample);
    if (count % 2 == 0) {
        CVPixelBufferRef shown = CVPixelBufferRetain(gPixels);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (AVCaptureVideoPreviewLayer *layer in gLayers.allObjects) {
                CALayer *sub = objc_getAssociatedObject(layer, &kSub);
                if (!sub) { sub = [CALayer layer]; sub.masksToBounds = YES; [layer addSublayer:sub]; layer.masksToBounds = YES; objc_setAssociatedObject(layer, &kSub, sub, OBJC_ASSOCIATION_RETAIN); }
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                sub.frame = layer.bounds;
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

static AVCaptureDevice *DefaultDevice(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? Camera() : nil; }
static AVCaptureDevice *DefaultDevice3(id s, SEL c, AVCaptureDeviceType dt, AVMediaType t, AVCaptureDevicePosition p) { return (!t || [t isEqualToString:AVMediaTypeVideo]) ? Camera() : nil; }
static NSArray *Devices(id s, SEL c) { return @[Camera()]; }
static NSArray *DevicesWith(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? @[Camera()] : @[]; }
static AVAuthorizationStatus Status(id s, SEL c, AVMediaType t) { return AVAuthorizationStatusAuthorized; }
static void Request(id s, SEL c, AVMediaType t, void (^done)(BOOL)) { if (done) dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(YES); }); }

static id (*oInputClass)(id, SEL, AVCaptureDevice *, NSError **);
static id InputClass(id s, SEL c, AVCaptureDevice *d, NSError **e) { if (d != Camera()) return oInputClass(s, c, d, e); SaguruInput *i = Bare(SaguruInput.class); i.fake = d; return i; }
static id (*oInputInit)(id, SEL, AVCaptureDevice *, NSError **);
static id InputInit(id s, SEL c, AVCaptureDevice *d, NSError **e) { if (d != Camera()) return oInputInit(s, c, d, e); SaguruInput *i = Bare(SaguruInput.class); i.fake = d; return i; }

static NSMutableArray *List(id session, char *key) { NSMutableArray *a = objc_getAssociatedObject(session, key); if (!a) { a = [NSMutableArray array]; objc_setAssociatedObject(session, key, a, OBJC_ASSOCIATION_RETAIN); [gSessions addObject:session]; } return a; }
static BOOL CanAdd(id s, SEL c, id x) { return YES; }
static void AddInput(id s, SEL c, id x) { if (x) [List(s, &kInputs) addObject:x]; }
static void AddOutput(id s, SEL c, id x) { if (x) [List(s, &kOutputs) addObject:x]; }
static void Remove(id s, SEL c, id x) { [(NSMutableArray *)objc_getAssociatedObject(s, &kInputs) removeObject:x]; [(NSMutableArray *)objc_getAssociatedObject(s, &kOutputs) removeObject:x]; }
// Read-only: a session being destroyed asks for these, and must not be registered again then.
static NSArray *Inputs(id s, SEL c) { return [objc_getAssociatedObject(s, &kInputs) copy] ?: @[]; }
static NSArray *Outputs(id s, SEL c) { return [objc_getAssociatedObject(s, &kOutputs) copy] ?: @[]; }
static void Start(id s, SEL c) { List(s, &kOutputs); objc_setAssociatedObject(s, &kRunning, @YES, OBJC_ASSOCIATION_RETAIN); NSLog(@"Saguru camera: session started"); }
static void Stop(id s, SEL c) { objc_setAssociatedObject(s, &kRunning, @NO, OBJC_ASSOCIATION_RETAIN); }
static BOOL Running(id s, SEL c) { return [objc_getAssociatedObject(s, &kRunning) boolValue]; }
static void Nothing(id s, SEL c) {}
static BOOL Yes1(id s, SEL c, id x) { return YES; }

static NSArray *MetaAvailable(id s, SEL c) { return @[AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code, AVMetadataObjectTypeEAN8Code, AVMetadataObjectTypeCode128Code, AVMetadataObjectTypePDF417Code, AVMetadataObjectTypeAztecCode, AVMetadataObjectTypeDataMatrixCode]; }
static void MetaSet(id s, SEL c, NSArray *types) { objc_setAssociatedObject(s, &kTypes, [types copy], OBJC_ASSOCIATION_RETAIN); }
static NSArray *MetaGet(id s, SEL c) { return objc_getAssociatedObject(s, &kTypes) ?: @[]; }

static void (*oSetSession)(id, SEL, AVCaptureSession *);
static void SetSession(id s, SEL c, AVCaptureSession *session) { [gLayers addObject:s]; oSetSession(s, c, session); }
static id (*oLayerInit)(id, SEL, AVCaptureSession *);
static id LayerInit(id s, SEL c, AVCaptureSession *session) { id layer = oLayerInit(s, c, session); if (layer) [gLayers addObject:layer]; return layer; }
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

static void Capture(AVCapturePhotoOutput *output, SEL c, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    dispatch_async(gFeed, ^{
        SaguruPhoto *photo = Bare(SaguruPhoto.class);
        if (gPixels) {
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            photo.jpeg = [gContext JPEGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:gPixels] colorSpace:space options:@{}];
            CGColorSpaceRelease(space);
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)])
            [delegate captureOutput:output didFinishProcessingPhoto:photo error:nil];
    });
}

__attribute__((constructor)) static void SaguruCameraLoad(void) {
    const char *folder = getenv("SAGURU_CAM_FOLDER");
    if (!folder) return;
    gFramePath = [@(folder) stringByAppendingPathComponent:@"frame.bgra"];
    gContext = [CIContext context];
    gDetect = dispatch_queue_create("dev.saguru.camera.codes", DISPATCH_QUEUE_SERIAL);
    gSessions = [NSHashTable weakObjectsHashTable]; gLayers = [NSHashTable weakObjectsHashTable];
    void *unused;
    Class dev = object_getClass(AVCaptureDevice.class);
    SWAP(dev, defaultDeviceWithMediaType:, DefaultDevice, unused);
    SWAP(dev, defaultDeviceWithDeviceType:mediaType:position:, DefaultDevice3, unused);
    SWAP(dev, devices, Devices, unused);
    SWAP(dev, devicesWithMediaType:, DevicesWith, unused);
    SWAP(dev, authorizationStatusForMediaType:, Status, unused);
    SWAP(dev, requestAccessForMediaType:completionHandler:, Request, unused);
    SWAP(AVCaptureDeviceDiscoverySession.class, devices, Devices, unused);
    SWAP(object_getClass(AVCaptureDeviceInput.class), deviceInputWithDevice:error:, InputClass, oInputClass);
    SWAP(AVCaptureDeviceInput.class, initWithDevice:error:, InputInit, oInputInit);
    Class ses = AVCaptureSession.class;
    SWAP(ses, canAddInput:, CanAdd, unused); SWAP(ses, canAddOutput:, CanAdd, unused);
    SWAP(ses, addInput:, AddInput, unused); SWAP(ses, addOutput:, AddOutput, unused);
    SWAP(ses, removeInput:, Remove, unused); SWAP(ses, removeOutput:, Remove, unused);
    SWAP(ses, inputs, Inputs, unused); SWAP(ses, outputs, Outputs, unused);
    SWAP(ses, startRunning, Start, unused); SWAP(ses, stopRunning, Stop, unused); SWAP(ses, isRunning, Running, unused);
    SWAP(ses, beginConfiguration, Nothing, unused); SWAP(ses, commitConfiguration, Nothing, unused);
    SWAP(ses, canSetSessionPreset:, Yes1, unused);
    Class meta = AVCaptureMetadataOutput.class;
    SWAP(meta, availableMetadataObjectTypes, MetaAvailable, unused); SWAP(meta, setMetadataObjectTypes:, MetaSet, unused); SWAP(meta, metadataObjectTypes, MetaGet, unused);
    Class layer = AVCaptureVideoPreviewLayer.class;
    SWAP(layer, setSession:, SetSession, oSetSession); SWAP(layer, initWithSession:, LayerInit, oLayerInit);
    SWAP(layer, transformedMetadataObjectForMetadataObject:, Transformed, unused);
    SWAP(AVCapturePhotoOutput.class, capturePhotoWithSettings:delegate:, Capture, unused);
    gFeed = dispatch_queue_create("dev.saguru.camera", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gFeed);
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{ Tick(); });
    dispatch_resume(gTimer);
}
