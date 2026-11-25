// NetDemo: a small shop screen that talks to a public demo API, used to try Saguru's network monitor.
#import <UIKit/UIKit.h>

static NSString *const kProduct = @"https://dummyjson.com/products/47";
static NSString *const kRelated = @"https://dummyjson.com/products/category/home-decoration?limit=4&select=title,price,thumbnail";

@interface Shop : UIViewController
@property UIImageView *photo; @property UILabel *name, *detail, *price, *state, *problem; @property UIButton *buy, *retry;
@property UIStackView *card, *related, *content; @property UIView *errorBox;
@end

@implementation Shop
- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *l = [UILabel new]; l.font = [UIFont systemFontOfSize:size weight:weight]; l.textColor = color; l.numberOfLines = lines; return l;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UILabel *title = [self label:32 weight:UIFontWeightBold color:UIColor.labelColor lines:1]; title.text = @"Tienda";
    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    [reload setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    reload.accessibilityLabel = @"Recargar"; [reload addTarget:self action:@selector(load) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, reload]]; header.distribution = UIStackViewDistributionEqualSpacing;

    self.photo = [UIImageView new]; self.photo.contentMode = UIViewContentModeScaleAspectFit; self.photo.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.photo.layer.cornerRadius = 14; self.photo.clipsToBounds = YES; [self.photo.heightAnchor constraintEqualToConstant:220].active = YES;
    self.name = [self label:22 weight:UIFontWeightSemibold color:UIColor.labelColor lines:2];
    self.detail = [self label:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor lines:3];
    self.price = [self label:26 weight:UIFontWeightBold color:UIColor.labelColor lines:1];
    UIButtonConfiguration *filled = [UIButtonConfiguration filledButtonConfiguration]; filled.title = @"Añadir al carrito"; filled.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    filled.contentInsets = NSDirectionalEdgeInsetsMake(13, 16, 13, 16);
    self.buy = [UIButton buttonWithConfiguration:filled primaryAction:nil]; [self.buy addTarget:self action:@selector(addToCart) forControlEvents:UIControlEventTouchUpInside];
    self.state = [self label:14 weight:UIFontWeightMedium color:UIColor.systemGreenColor lines:1]; self.state.textAlignment = NSTextAlignmentCenter;
    self.card = [[UIStackView alloc] initWithArrangedSubviews:@[self.photo, self.name, self.detail, self.price, self.buy, self.state]];
    self.card.axis = UILayoutConstraintAxisVertical; self.card.spacing = 10; [self.card setCustomSpacing:16 afterView:self.photo]; [self.card setCustomSpacing:16 afterView:self.price];

    UILabel *more = [self label:17 weight:UIFontWeightSemibold color:UIColor.labelColor lines:1]; more.text = @"También te puede gustar";
    self.related = [UIStackView new]; self.related.spacing = 10; self.related.distribution = UIStackViewDistributionFillEqually;
    [self.related.heightAnchor constraintEqualToConstant:78].active = YES;

    self.problem = [self label:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor lines:0]; self.problem.textAlignment = NSTextAlignmentCenter;
    UIImageView *sign = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi.exclamationmark"]]; sign.tintColor = UIColor.systemOrangeColor; sign.contentMode = UIViewContentModeScaleAspectFit;
    [sign.heightAnchor constraintEqualToConstant:54].active = YES;
    UILabel *oops = [self label:20 weight:UIFontWeightSemibold color:UIColor.labelColor lines:1]; oops.text = @"No se pudo cargar el producto"; oops.textAlignment = NSTextAlignmentCenter;
    self.retry = [UIButton buttonWithType:UIButtonTypeSystem]; [self.retry setTitle:@"Reintentar" forState:UIControlStateNormal]; self.retry.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.retry addTarget:self action:@selector(load) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *error = [[UIStackView alloc] initWithArrangedSubviews:@[sign, oops, self.problem, self.retry]]; error.axis = UILayoutConstraintAxisVertical; error.spacing = 12;
    error.layoutMargins = UIEdgeInsetsMake(60, 10, 40, 10); error.layoutMarginsRelativeArrangement = YES; self.errorBox = error;

    self.content = [[UIStackView alloc] initWithArrangedSubviews:@[header, self.card, error, more, self.related]];
    self.content.axis = UILayoutConstraintAxisVertical; self.content.spacing = 16; self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.content setCustomSpacing:26 afterView:self.card];
    [self.view addSubview:self.content];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[self.content.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.content.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20], [self.content.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20]]];
    [self load];
}
- (void)get:(NSString *)url then:(void (^)(NSData *, NSInteger, NSError *))done {
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger status = [(NSHTTPURLResponse *)r statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{ done(d, status, e); });
    }] resume];
}
- (void)load {
    self.card.hidden = NO; self.errorBox.hidden = YES; self.state.text = @""; self.name.text = @"Cargando…"; self.detail.text = @""; self.price.text = @""; self.photo.image = nil; self.buy.enabled = NO;
    [self get:kProduct then:^(NSData *d, NSInteger status, NSError *e) {
        NSDictionary *p = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (e || status != 200 || ![p isKindOfClass:NSDictionary.class] || !p[@"title"]) {
            self.card.hidden = YES; self.errorBox.hidden = NO;
            self.problem.text = e ? e.localizedDescription : [NSString stringWithFormat:@"El servidor respondió %ld. Inténtalo de nuevo en un momento.", (long)status];
            return;
        }
        self.name.text = p[@"title"]; self.detail.text = p[@"description"]; self.price.text = [NSString stringWithFormat:@"$%.2f", [p[@"price"] doubleValue]]; self.buy.enabled = YES;
        NSString *image = [p[@"images"] firstObject] ?: p[@"thumbnail"];
        if (image) [self get:image then:^(NSData *data, NSInteger s, NSError *err) { self.photo.image = data ? [UIImage imageWithData:data] : nil; }];
    }];
    for (UIView *v in self.related.arrangedSubviews) [v removeFromSuperview];
    [self get:kRelated then:^(NSData *d, NSInteger status, NSError *e) {
        NSDictionary *list = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (![list isKindOfClass:NSDictionary.class]) return;
        for (NSDictionary *item in list[@"products"]) {
            UIImageView *thumb = [UIImageView new]; thumb.contentMode = UIViewContentModeScaleAspectFit; thumb.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
            thumb.layer.cornerRadius = 12; thumb.clipsToBounds = YES; [self.related addArrangedSubview:thumb];
            [self get:item[@"thumbnail"] then:^(NSData *data, NSInteger s, NSError *err) { thumb.image = data ? [UIImage imageWithData:data] : nil; }];
        }
    }];
}
- (void)addToCart {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://dummyjson.com/carts/add"]];
    r.HTTPMethod = @"POST"; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [r setValue:@"Bearer demo-token" forHTTPHeaderField:@"Authorization"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"userId": @1, @"products": @[@{@"id": @47, @"quantity": @1}]} options:0 error:nil];
    self.state.textColor = UIColor.secondaryLabelColor; self.state.text = @"Añadiendo…";
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger status = [(NSHTTPURLResponse *)resp statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = !e && status >= 200 && status < 300;
            self.state.textColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
            self.state.text = ok ? @"Añadido al carrito" : [NSString stringWithFormat:@"No se pudo añadir (%ld)", (long)status];
        });
    }] resume];
}
@end
@interface AD : UIResponder <UIApplicationDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [Shop new]; [self.window makeKeyAndVisible]; return YES; }
@end
int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"AD"); } }
