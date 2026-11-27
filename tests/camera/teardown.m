// Replays an ID scanner's life with Saguru's camera: set up, run, take photos, then tear down twice
// the way the app does, releasing everything. Prints each step so a crash shows where.
#import <AVFoundation/AVFoundation.h>
@interface D : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate> @property int frames, photos; @end
@implementation D
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c { self.frames++; usleep(20000); }
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)p error:(NSError *)e { self.photos++; (void)p.fileDataRepresentation; }
@end
#define STEP(...) do { printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
static void Round(int n) {
    @autoreleasepool {
        STEP("-- vuelta %d: montar", n);
        AVCaptureSession *session = [AVCaptureSession new];
        [session beginConfiguration];
        session.sessionPreset = AVCaptureSessionPreset1920x1080;
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL];
        [session addInput:input];
        AVCaptureVideoDataOutput *video = [AVCaptureVideoDataOutput new];
        AVCapturePhotoOutput *photo = [AVCapturePhotoOutput new];
        D *d = [D new];
        dispatch_queue_t q = dispatch_queue_create("frames", DISPATCH_QUEUE_SERIAL);
        [video setSampleBufferDelegate:d queue:q];
        [session addOutput:video]; [session addOutput:photo];
        [video connectionWithMediaType:AVMediaTypeVideo].videoRotationAngle = 90;
        AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:session];
        layer.connection.videoRotationAngle = 90;
        [session commitConfiguration];
        [session startRunning];
        usleep(700000);
        STEP("fotogramas %d", d.frames);
        [photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:d];
        usleep(300000);
        [photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:d];
        usleep(300000);
        STEP("fotos %d; desmontar (1)", d.photos);
        for (int close = 0; close < 2; close++) {
            [video setSampleBufferDelegate:nil queue:nil];
            if ([device lockForConfiguration:NULL]) { if (device.hasTorch) device.torchMode = AVCaptureTorchModeOff; [device unlockForConfiguration]; }
            if (session.isRunning) [session stopRunning];
        }
        STEP("soltar capa"); layer.session = nil; layer = nil;
        STEP("soltar delegado"); d = nil;
        STEP("soltar salidas"); video = nil; photo = nil;
        STEP("soltar entrada"); input = nil;
        STEP("soltar sesión"); session = nil;
    }
    STEP("vuelta %d terminada", n);
    usleep(300000);
}
int main(void) { for (int i = 1; i <= 3; i++) Round(i); STEP("TODO BIEN"); return 0; }
