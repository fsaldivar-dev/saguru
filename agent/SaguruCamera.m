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
#import <objc/message.h>
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
static char kInputs, kOutputs, kRunning, kTypes, kSub, kBusy, kPickerCamera, kPickerShown;

// MARK: Pretend objects (never initialised the normal way: created bare and answered by these overrides)

@interface SaguruCamera : AVCaptureDevice @property (nonatomic) AVCaptureDevicePosition spot; @end
@implementation SaguruCamera
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
                // Like a real camera, a frame is dropped while the app is still busy with the previous one.
                if ([objc_getAssociatedObject(video, &kBusy) boolValue]) continue;
                objc_setAssociatedObject(video, &kBusy, @YES, OBJC_ASSOCIATION_RETAIN);
                CFRetain(sample);
                dispatch_async(video.sampleBufferCallbackQueue ?: dispatch_get_main_queue(), ^{
                    [delegate captureOutput:video didOutputSampleBuffer:sample fromConnection:(id)nil]; CFRelease(sample);
                    objc_setAssociatedObject(video, &kBusy, @NO, OBJC_ASSOCIATION_RETAIN); });
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

static AVCaptureDevice *DefaultDevice(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? Camera(AVCaptureDevicePositionBack) : nil; }
static AVCaptureDevice *DefaultDevice3(id s, SEL c, AVCaptureDeviceType dt, AVMediaType t, AVCaptureDevicePosition p) { return (!t || [t isEqualToString:AVMediaTypeVideo]) ? Camera(p) : nil; }
static NSArray *Devices(id s, SEL c) { return @[Camera(AVCaptureDevicePositionBack), Camera(AVCaptureDevicePositionFront)]; }
static NSArray *DevicesWith(id s, SEL c, AVMediaType t) { return [t isEqualToString:AVMediaTypeVideo] ? Devices(s, c) : @[]; }
static AVAuthorizationStatus Status(id s, SEL c, AVMediaType t) { return AVAuthorizationStatusAuthorized; }
static void Request(id s, SEL c, AVMediaType t, void (^done)(BOOL)) { if (done) dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(YES); }); }

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

static NSMutableArray *List(id session, char *key) { NSMutableArray *a = objc_getAssociatedObject(session, key); if (!a) { a = [NSMutableArray array]; objc_setAssociatedObject(session, key, a, OBJC_ASSOCIATION_RETAIN); [gSessions addObject:session]; } return a; }
static BOOL CanAdd(id s, SEL c, id x) { return YES; }
static void AddInput(id s, SEL c, id x) { if (x && ![List(s, &kInputs) containsObject:x]) [List(s, &kInputs) addObject:x]; }
static void AddOutput(id s, SEL c, id x) { if (x && ![List(s, &kOutputs) containsObject:x]) [List(s, &kOutputs) addObject:x]; }
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
