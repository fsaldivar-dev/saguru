// One camera flow per run, named by the first argument, with Saguru's agent loaded. Each prints OK at the
// end; a crash or an exception means that flow needs work. Flows are the ways apps really use a camera.
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
@interface D : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate, AVCaptureFileOutputRecordingDelegate>
@property int frames, photos, codes, recorded; @property (strong) NSString *note; @end
@implementation D
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c { self.frames++; (void)c.videoRotationAngle; (void)c.isVideoMirrored; usleep(5000); }
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {}
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)p error:(NSError *)e { self.photos++; (void)p.fileDataRepresentation; (void)p.CGImageRepresentation; (void)p.metadata; (void)p.resolvedSettings.photoDimensions; (void)p.previewPixelBuffer; (void)p.depthData; (void)p.pixelBuffer; }
- (void)captureOutput:(AVCaptureOutput *)o didOutputMetadataObjects:(NSArray *)m fromConnection:(AVCaptureConnection *)c { self.codes += (int)m.count; for (AVMetadataMachineReadableCodeObject *x in m) { (void)x.stringValue; (void)x.corners; (void)x.bounds; (void)x.type; (void)x.description; } }
- (void)captureOutput:(AVCaptureFileOutput *)o didFinishRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c error:(NSError *)e { self.recorded++; self.note = e.localizedDescription; }
@end
@interface Old : NSObject <AVCapturePhotoCaptureDelegate> @property int photos; @property (strong) NSData *data; @end
@implementation Old
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)b previewPhotoSampleBuffer:(CMSampleBufferRef)pb resolvedSettings:(AVCaptureResolvedPhotoSettings *)r bracketSettings:(AVCaptureBracketedStillImageSettings *)bs error:(NSError *)e {
    self.photos++; if (b) self.data = [AVCapturePhotoOutput JPEGPhotoDataRepresentationForJPEGSampleBuffer:b previewPhotoSampleBuffer:pb];
}
#pragma clang diagnostic pop
@end
@interface Watcher : NSObject @property int changes; @end
@implementation Watcher
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)x { self.changes++; }
@end
#define SAY(...) do { printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
static AVCaptureDevice *Cam(AVCaptureDevicePosition p) { return [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:p]; }
static void Wait(double s) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }

int main(int argc, char **argv) { @autoreleasepool {
    NSString *flow = argc > 1 ? @(argv[1]) : @"";
    D *d = [D new];
    dispatch_queue_t q = dispatch_queue_create("frames", DISPATCH_QUEUE_SERIAL);
    AVCaptureSession *session = [AVCaptureSession new];
    AVCaptureDevice *back = Cam(AVCaptureDevicePositionBack), *front = Cam(AVCaptureDevicePositionFront);
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:back error:NULL];
    AVCaptureVideoDataOutput *video = [AVCaptureVideoDataOutput new];
    AVCapturePhotoOutput *photo = [AVCapturePhotoOutput new];

    if ([flow isEqual:@"describe"]) {            // apps log their objects all the time
        [session addInput:input]; [session addOutput:video]; [session addOutput:photo];
        AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:session];
        NSArray *things = @[back, front, back.activeFormat, input, [video connectionWithMediaType:AVMediaTypeVideo], layer.connection, session, video, photo];
        for (id thing in things) { SAY("%s", [[thing description] UTF8String]); (void)[thing debugDescription]; (void)[NSString stringWithFormat:@"%@", thing]; }
        SAY("iguales %d distintos %d hash %d", [back isEqual:Cam(AVCaptureDevicePositionBack)], [back isEqual:front], back.hash == Cam(AVCaptureDevicePositionBack).hash);
        NSSet *set = [NSSet setWithObjects:back, front, back, nil]; NSDictionary *byID = @{back.uniqueID: back}; SAY("conjunto %lu %lu", (unsigned long)set.count, (unsigned long)byID.count);
    } else if ([flow isEqual:@"structs"]) {      // values Apple returns as structures
        [back lockForConfiguration:NULL];
        (void)back.exposureDuration; (void)back.deviceWhiteBalanceGains; (void)back.grayWorldDeviceWhiteBalanceGains; (void)back.activeMaxExposureDuration;
        (void)back.activeVideoMinFrameDuration; (void)back.focusPointOfInterest; (void)back.exposurePointOfInterest; (void)back.ISO; (void)back.lensAperture; (void)back.exposureTargetOffset;
        (void)[back chromaticityValuesForDeviceWhiteBalanceGains:(AVCaptureWhiteBalanceGains){1, 1, 1}];
        (void)[back temperatureAndTintValuesForDeviceWhiteBalanceGains:(AVCaptureWhiteBalanceGains){1, 1, 1}];
        (void)[back deviceWhiteBalanceGainsForTemperatureAndTintValues:(AVCaptureWhiteBalanceTemperatureAndTintValues){5000, 0}];
        [back setExposureModeCustomWithDuration:CMTimeMake(1, 60) ISO:100 completionHandler:nil];
        [back setFocusModeLockedWithLensPosition:0.5 completionHandler:nil];
        [back setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:(AVCaptureWhiteBalanceGains){1, 1, 1} completionHandler:nil];
        [back setExposureTargetBias:0 completionHandler:nil];
        back.activeVideoMinFrameDuration = CMTimeMake(1, 30); back.activeVideoMaxFrameDuration = CMTimeMake(1, 30);
        AVCaptureDeviceFormat *f = back.activeFormat;
        (void)f.minExposureDuration; (void)f.maxExposureDuration; (void)f.highResolutionStillImageDimensions; (void)f.videoSupportedFrameRateRanges; (void)f.supportedMaxPhotoDimensions; (void)f.formatDescription; (void)f.videoFieldOfView;
        for (AVCaptureDeviceFormat *each in back.formats) { (void)CMVideoFormatDescriptionGetDimensions(each.formatDescription); for (AVFrameRateRange *r in each.videoSupportedFrameRateRanges) (void)r.maxFrameRate; }
        back.activeFormat = f; (void)back.systemPressureState; (void)back.minExposureTargetBias; (void)back.videoZoomFactor; back.videoZoomFactor = 2; [back rampToVideoZoomFactor:1 withRate:2];
        [back unlockForConfiguration];
    } else if ([flow isEqual:@"switch"]) {       // front and back, over and over, while running
        [video setSampleBufferDelegate:d queue:q]; [session addInput:input]; [session addOutput:video]; [session startRunning];
        for (int i = 0; i < 12; i++) {
            [session beginConfiguration];
            for (AVCaptureInput *each in session.inputs) [session removeInput:each];
            AVCaptureDeviceInput *next = [[AVCaptureDeviceInput alloc] initWithDevice:(i % 2 ? back : front) error:NULL];
            if ([session canAddInput:next]) [session addInput:next];
            [video connectionWithMediaType:AVMediaTypeVideo].videoMirrored = i % 2 == 0;
            [session commitConfiguration]; Wait(0.08);
        }
        SAY("fotogramas %d", d.frames);
    } else if ([flow isEqual:@"churn"]) {        // start, stop and change outputs from several threads at once
        [video setSampleBufferDelegate:d queue:q]; [session addInput:input]; [session addOutput:video];
        dispatch_group_t g = dispatch_group_create();
        for (int t = 0; t < 4; t++) dispatch_group_async(g, dispatch_get_global_queue(0, 0), ^{
            for (int i = 0; i < 60; i++) { @autoreleasepool {
                if (i % 3 == 0) [session startRunning]; else if (i % 3 == 1) [session stopRunning];
                AVCaptureVideoDataOutput *extra = [AVCaptureVideoDataOutput new]; [extra setSampleBufferDelegate:d queue:q];
                [session addOutput:extra]; (void)session.outputs.count; (void)session.inputs.count; (void)session.connections; usleep(2000); [session removeOutput:extra]; [extra setSampleBufferDelegate:nil queue:nil];
            } }
        });
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER); SAY("fotogramas %d", d.frames);
    } else if ([flow isEqual:@"sessions"]) {     // many short-lived sessions, each let go while running
        for (int i = 0; i < 25; i++) { @autoreleasepool {
            AVCaptureSession *s = [AVCaptureSession new]; AVCaptureVideoDataOutput *v = [AVCaptureVideoDataOutput new]; D *each = [D new];
            [v setSampleBufferDelegate:each queue:q]; [s addInput:[AVCaptureDeviceInput deviceInputWithDevice:back error:NULL]]; [s addOutput:v];
            AVCaptureVideoPreviewLayer *l = [[AVCaptureVideoPreviewLayer alloc] initWithSession:s]; l.frame = CGRectMake(0, 0, 200, 300); (void)l.connection.videoRotationAngle;
            [s startRunning]; Wait(0.05);
        } }
        Wait(0.3);
    } else if ([flow isEqual:@"layer"]) {        // the preview layer's own conversions and odd orders
        AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer new]; layer.frame = CGRectMake(0, 0, 300, 500);
        (void)layer.connection; layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [session addInput:input]; layer.session = session; [session startRunning]; Wait(0.2);
        CGPoint p = [layer captureDevicePointOfInterestForPoint:CGPointMake(150, 250)]; CGPoint back2 = [layer pointForCaptureDevicePointOfInterest:p];
        CGRect r = [layer metadataOutputRectOfInterestForRect:CGRectMake(50, 100, 200, 200)]; CGRect r2 = [layer rectForMetadataOutputRectOfInterest:r];
        SAY("punto %.2f,%.2f vuelve %.0f,%.0f · rect %.2f %.2f %.2f %.2f vuelve %.0f %.0f %.0f %.0f", p.x, p.y, back2.x, back2.y, r.origin.x, r.origin.y, r.size.width, r.size.height, r2.origin.x, r2.origin.y, r2.size.width, r2.size.height);
        (void)layer.isPreviewing; layer.connection.videoRotationAngle = 0; layer.connection.videoMirrored = YES; Wait(0.2);
        [layer setSessionWithNoConnection:session]; layer.session = nil; layer.session = session; Wait(0.1); [layer removeFromSuperlayer]; layer = nil; Wait(0.1);
    } else if ([flow isEqual:@"photo"]) {        // settings the way sample code writes them
        [session addInput:input]; [session addOutput:photo]; [session startRunning]; Wait(0.3);
        AVCapturePhotoSettings *s = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
        SAY("vistas previas %lu miniaturas %lu", (unsigned long)s.availablePreviewPhotoPixelFormatTypes.count, (unsigned long)s.availableEmbeddedThumbnailPhotoCodecTypes.count);
        if (s.availablePreviewPhotoPixelFormatTypes.count) s.previewPhotoFormat = @{(id)kCVPixelBufferPixelFormatTypeKey: s.availablePreviewPhotoPixelFormatTypes.firstObject};
        s.flashMode = AVCaptureFlashModeOff; s.photoQualityPrioritization = AVCapturePhotoQualityPrioritizationBalanced;
        (void)photo.isDepthDataDeliverySupported; (void)photo.isLivePhotoCaptureSupported; (void)photo.isPortraitEffectsMatteDeliverySupported; (void)photo.availablePhotoFileTypes; (void)photo.availableRawPhotoPixelFormatTypes; (void)photo.isFlashScene; (void)photo.photoSettingsForSceneMonitoring;
        [photo setPreparedPhotoSettingsArray:@[s] completionHandler:^(BOOL ok, NSError *e) { d.note = ok ? @"preparada" : @"sin preparar"; }];
        [photo capturePhotoWithSettings:s delegate:d]; Wait(0.5);
        Old *old = [Old new]; [photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:old]; Wait(0.5);
        @autoreleasepool { D *gone = [D new]; [photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:gone]; }   // delegate let go at once
        [session stopRunning]; [photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:d]; Wait(0.5);
        SAY("fotos %d · antiguas %d con %lu bytes · %s", d.photos, old.photos, (unsigned long)old.data.length, d.note.UTF8String ?: "-");
    } else if ([flow isEqual:@"still"]) {        // the oldest still-image API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
        AVCaptureStillImageOutput *still = [AVCaptureStillImageOutput new]; still.outputSettings = @{AVVideoCodecKey: AVVideoCodecJPEG};
        [session addInput:input]; [session addOutput:still]; [session startRunning]; Wait(0.3);
        __block NSUInteger bytes = 0; __block int called = 0;
        [still captureStillImageAsynchronouslyFromConnection:[still connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef b, NSError *e) {
            called++; if (b) bytes = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:b].length; }];
        Wait(0.6); SAY("llamadas %d bytes %lu", called, (unsigned long)bytes);
#pragma clang diagnostic pop
    } else if ([flow isEqual:@"movie"]) {        // recording is not offered: it must fail politely
        AVCaptureMovieFileOutput *movie = [AVCaptureMovieFileOutput new]; [session addInput:input];
        if ([session canAddOutput:movie]) [session addOutput:movie];
        [session startRunning]; Wait(0.2);
        [movie startRecordingToOutputFileURL:[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"x.mov"]] recordingDelegate:d]; Wait(0.4);
        (void)movie.isRecording; [movie stopRecording]; Wait(0.3); SAY("avisos %d: %s", d.recorded, d.note.UTF8String ?: "-");
    } else if ([flow isEqual:@"meta"]) {         // codes, with a rect of interest
        AVCaptureMetadataOutput *meta = [AVCaptureMetadataOutput new]; [session addInput:input]; [session addOutput:meta];
        [meta setMetadataObjectsDelegate:d queue:dispatch_get_main_queue()];
        meta.metadataObjectTypes = [meta.availableMetadataObjectTypes filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", @[AVMetadataObjectTypeQRCode, AVMetadataObjectTypePDF417Code]]];
        meta.rectOfInterest = CGRectMake(0.2, 0.2, 0.6, 0.6); (void)[meta connectionWithMediaType:AVMediaTypeMetadata]; (void)meta.connections;
        [session startRunning]; Wait(0.8); [meta setMetadataObjectsDelegate:nil queue:nil]; [session removeOutput:meta]; Wait(0.2); SAY("códigos %d", d.codes);
    } else if ([flow isEqual:@"observe"]) {      // key-value observing, as focus and exposure indicators do
        Watcher *w = [Watcher new];
        for (NSString *key in @[@"adjustingFocus", @"adjustingExposure", @"torchMode", @"videoZoomFactor", @"lensPosition", @"ISO", @"systemPressureState"]) [back addObserver:w forKeyPath:key options:NSKeyValueObservingOptionNew context:NULL];
        [session addObserver:w forKeyPath:@"running" options:0 context:NULL];
        [session addInput:input]; [session startRunning]; [back lockForConfiguration:NULL]; back.torchMode = AVCaptureTorchModeOn; back.videoZoomFactor = 2; [back unlockForConfiguration]; Wait(0.3); [session stopRunning];
        for (NSString *key in @[@"adjustingFocus", @"adjustingExposure", @"torchMode", @"videoZoomFactor", @"lensPosition", @"ISO", @"systemPressureState"]) [back removeObserver:w forKeyPath:key];
        [session removeObserver:w forKeyPath:@"running"]; SAY("cambios vistos %d", w.changes);
    } else if ([flow isEqual:@"audio"]) {        // the microphone is not Saguru's business and must stay as it was
        AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        AVCaptureDeviceDiscoverySession *found = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
        SAY("micrófono %s · en la búsqueda %lu · permiso %ld", mic ? mic.localizedName.UTF8String : "ninguno", (unsigned long)found.devices.count, (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]);
        for (AVCaptureDevice *each in found.devices) SAY("  %s %d", each.localizedName.UTF8String, [each hasMediaType:AVMediaTypeAudio]);
        if (mic) { AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:mic error:NULL]; if (in && [session canAddInput:in]) [session addInput:in]; }
        [session addInput:input]; [session startRunning]; Wait(0.2);
    } else if ([flow isEqual:@"manual"]) {       // sessions wired by hand, as multi-camera code does
        [session addInputWithNoConnections:input]; [session addOutputWithNoConnections:video]; [video setSampleBufferDelegate:d queue:q];
        AVCaptureInputPort *port = input.ports.firstObject;
        if (port) { AVCaptureConnection *c = [AVCaptureConnection connectionWithInputPorts:@[port] output:video]; if ([session canAddConnection:c]) [session addConnection:c]; }
        SAY("puertos %lu", (unsigned long)input.ports.count); [session startRunning]; Wait(0.4); SAY("fotogramas %d", d.frames);
    } else if ([flow isEqual:@"discover"]) {     // every way of finding a camera
        NSArray *types = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInTripleCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera];
        for (NSNumber *p in @[@(AVCaptureDevicePositionBack), @(AVCaptureDevicePositionFront), @(AVCaptureDevicePositionUnspecified)]) {
            AVCaptureDeviceDiscoverySession *s2 = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:AVMediaTypeVideo position:p.integerValue];
            SAY("posición %ld: %lu", (long)p.integerValue, (unsigned long)s2.devices.count); (void)s2.supportedMultiCamDeviceSets;
        }
        for (AVCaptureDeviceType t in types) { AVCaptureDevice *x = [AVCaptureDevice defaultDeviceWithDeviceType:t mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack]; SAY("%s → %s", t.UTF8String, x ? x.localizedName.UTF8String : "ninguna"); }
        AVCaptureDevice *byID = [AVCaptureDevice deviceWithUniqueID:back.uniqueID]; SAY("por id: %s · preferida %s", byID ? "sí" : "no", AVCaptureDevice.userPreferredCamera ? "sí" : "no");
        (void)AVCaptureDevice.systemPreferredCamera; (void)back.manufacturer; (void)back.constituentDevices; (void)back.isVirtualDevice; (void)back.isContinuityCamera; (void)[back supportsAVCaptureSessionPreset:AVCaptureSessionPresetHigh];
    } else { SAY("flujo desconocido"); return 2; }
    SAY("OK");
} return 0; }
