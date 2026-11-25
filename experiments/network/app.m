#import <UIKit/UIKit.h>
@interface VC : UIViewController
@property UILabel *label; @property UIImageView *image; @property UILabel *post;
@end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Recargar" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [b addTarget:self action:@selector(load) forControlEvents:UIControlEventTouchUpInside];
    self.label = [UILabel new]; self.label.numberOfLines = 0; self.label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.post = [UILabel new]; self.post.numberOfLines = 2; self.post.font = [UIFont systemFontOfSize:14];
    self.image = [UIImageView new]; self.image.contentMode = UIViewContentModeScaleAspectFit;
    [self.image.heightAnchor constraintEqualToConstant:140].active = YES;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[b, self.label, self.image, self.post]];
    s.axis = UILayoutConstraintAxisVertical; s.spacing = 16; s.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:s];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:g.topAnchor constant:20],
        [s.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20], [s.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20]]];
    [self load];
}
- (void)load {
    self.label.text = @"Cargando…"; self.image.image = nil; self.post.text = @"";
    NSURLSession *s = NSURLSession.sharedSession;
    [[s dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/json?usuario=42"] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *t = e ? e.localizedDescription : [NSString stringWithFormat:@"HTTP %ld\n%@", (long)[(NSHTTPURLResponse *)r statusCode], [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, 260))] encoding:NSUTF8StringEncoding]];
        dispatch_async(dispatch_get_main_queue(), ^{ self.label.text = t; });
    }] resume];
    NSURLSession *own = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[own dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/image/png"] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.image.image = d ? [UIImage imageWithData:d] : nil; });
    }] resume];
    NSMutableURLRequest *p = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://httpbin.org/post"]];
    p.HTTPMethod = @"POST"; p.HTTPBody = [@"{\"producto\":\"taza\",\"cantidad\":2}" dataUsingEncoding:NSUTF8StringEncoding];
    [p setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [p setValue:@"Bearer demo-token" forHTTPHeaderField:@"Authorization"];
    [[own dataTaskWithRequest:p completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.post.text = [NSString stringWithFormat:@"POST → %ld (%lu bytes)", (long)[(NSHTTPURLResponse *)r statusCode], (unsigned long)d.length]; });
    }] resume];
    [[s dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/status/503"]] resume];
    [[s dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/bytes/2048"]] resume];
}
@end
@interface AD : UIResponder <UIApplicationDelegate> @property UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [VC new]; [self.window makeKeyAndVisible]; return YES; }
@end
int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"AD"); } }
