#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
@interface VC : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate>
@property AVCaptureSession *session; @property AVCapturePhotoOutput *photo; @property AVCaptureVideoPreviewLayer *preview;
@property UILabel *l1, *l2, *l3, *l4, *l5; @property NSInteger frames; @property UIImageView *shot;
@end
@implementation VC
- (UILabel *)label { UILabel *l = [UILabel new]; l.numberOfLines = 3; l.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]; l.text = @"-"; return l; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIView *pv = [UIView new]; pv.backgroundColor = UIColor.blackColor; [pv.heightAnchor constraintEqualToConstant:300].active = YES;
    self.l1 = [self label]; self.l2 = [self label]; self.l3 = [self label]; self.l4 = [self label]; self.l5 = [self label];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:@"Foto" forState:UIControlStateNormal]; [b addTarget:self action:@selector(take) forControlEvents:UIControlEventTouchUpInside];
    self.shot = [UIImageView new]; self.shot.contentMode = UIViewContentModeScaleAspectFit; [self.shot.heightAnchor constraintEqualToConstant:90].active = YES;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[pv, self.l1, self.l2, self.l3, self.l4, b, self.l5, self.shot]];
    s.axis = UILayoutConstraintAxisVertical; s.spacing = 8; s.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:s];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:g.topAnchor constant:8], [s.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:14], [s.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-14]]];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL ok) { dispatch_async(dispatch_get_main_queue(), ^{ [self start:pv ok:ok]; }); }];
}
- (void)start:(UIView *)pv ok:(BOOL)ok {
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    self.l1.text = [NSString stringWithFormat:@"1 dispositivo: %@ (permiso %d)", d.localizedName ?: @"NINGUNO", ok];
    if (!d) return;
    NSError *e; AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:d error:&e];
    self.session = [AVCaptureSession new]; [self.session beginConfiguration];
    self.session.sessionPreset = AVCaptureSessionPresetHigh;
    if (in && [self.session canAddInput:in]) [self.session addInput:in]; else { self.l1.text = [NSString stringWithFormat:@"1 sin entrada: %@", e.localizedDescription]; }
    AVCaptureVideoDataOutput *v = [AVCaptureVideoDataOutput new];
    v.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    [v setSampleBufferDelegate:self queue:dispatch_queue_create("frames", 0)];
    if ([self.session canAddOutput:v]) [self.session addOutput:v];
    AVCaptureMetadataOutput *m = [AVCaptureMetadataOutput new];
    if ([self.session canAddOutput:m]) { [self.session addOutput:m]; [m setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        if ([m.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) m.metadataObjectTypes = @[AVMetadataObjectTypeQRCode]; else self.l3.text = @"3 metadata: QR no disponible"; }
    self.photo = [AVCapturePhotoOutput new]; if ([self.session canAddOutput:self.photo]) [self.session addOutput:self.photo];
    [self.session commitConfiguration];
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session]; self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.preview.frame = CGRectMake(0, 0, self.view.bounds.size.width - 28, 300); [pv.layer addSublayer:self.preview];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ [self.session startRunning]; });
}
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    NSInteger n = ++self.frames; CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    if (n % 15 == 1) {
        VNDetectBarcodesRequest *r = [VNDetectBarcodesRequest new]; NSError *e; NSString *how = @"normal";
        [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}] performRequests:@[r] error:&e];
        if (e) { e = nil; how = @"soloCPU"; r = [VNDetectBarcodesRequest new]; r.usesCPUOnly = YES; [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}] performRequests:@[r] error:&e]; }
        if (e) { e = nil; how = @"rev1"; r = [VNDetectBarcodesRequest new]; r.revision = VNDetectBarcodesRequestRevision1; r.usesCPUOnly = YES; [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}] performRequests:@[r] error:&e]; }
        VNRecognizeTextRequest *t = [VNRecognizeTextRequest new]; NSError *te; [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}] performRequests:@[t] error:&te];
        NSString *text = [[(VNRecognizedTextObservation *)t.results.firstObject topCandidates:1].firstObject string] ?: te.localizedDescription;
        NSString *p = [(VNBarcodeObservation *)r.results.firstObject payloadStringValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.l2.text = [NSString stringWithFormat:@"2 fotogramas: %ld (%zux%zu)", (long)n, w, h];
            self.l4.text = [NSString stringWithFormat:@"4 Vision QR(%@): %@ | texto: %@", how, p ?: (e.localizedDescription ?: @"nada"), text]; });
    }
}
- (void)captureOutput:(AVCaptureOutput *)o didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)objs fromConnection:(AVCaptureConnection *)c {
    AVMetadataMachineReadableCodeObject *q = objs.firstObject;
    AVMetadataObject *t = [self.preview transformedMetadataObjectForMetadataObject:q];
    self.l3.text = [NSString stringWithFormat:@"3 metadata: %@ en %@", q.stringValue, NSStringFromCGRect(t.bounds)];
}
- (void)take { self.l5.text = @"5 foto: pidiendo…"; [self.photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:self]; }
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)p error:(NSError *)e {
    NSData *d = p.fileDataRepresentation; UIImage *i = d ? [UIImage imageWithData:d] : nil;
    self.l5.text = [NSString stringWithFormat:@"5 foto: %lu bytes %@ %@", (unsigned long)d.length, NSStringFromCGSize(i.size), e.localizedDescription ?: @""]; self.shot.image = i;
}
@end
@interface AD : UIResponder <UIApplicationDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o { self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = [VC new]; [self.window makeKeyAndVisible]; return YES; }
@end
int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"AD"); } }
