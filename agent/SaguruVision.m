// SaguruVision: makes Vision usable in the iOS Simulator for the requests that have a version that runs there.
// The newest revisions of some detectors need hardware the Simulator lacks: the barcode detector returns
// nothing from revision 3 on, and the face detector fails at revision 3. Their older revisions work, so a
// request about to run is moved to one of those. Requests with no working revision (face landmarks, people,
// image classification) are left alone and keep failing, as they do without Saguru.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface NSObject (SaguruVisionRequest)
- (NSUInteger)revision;
- (void)setRevision:(NSUInteger)revision;
@end

static void Lower(NSArray *requests) {
    static Class barcodes, faces; static dispatch_once_t once;
    dispatch_once(&once, ^{ barcodes = NSClassFromString(@"VNDetectBarcodesRequest"); faces = NSClassFromString(@"VNDetectFaceRectanglesRequest"); });
    for (id request in requests) {
        if (([request isKindOfClass:barcodes] || [request isKindOfClass:faces]) && [request revision] > 2) [request setRevision:2];
    }
}

static BOOL (*oImagePerform)(id, SEL, NSArray *, NSError **);
static BOOL ImagePerform(id s, SEL c, NSArray *requests, NSError **error) { Lower(requests); return oImagePerform(s, c, requests, error); }

// The sequence handler takes the picture as its second argument, in several flavours that all end the same way.
static BOOL (*oSequenceObject)(id, SEL, NSArray *, id, NSError **);
static BOOL SequenceObject(id s, SEL c, NSArray *requests, id picture, NSError **error) { Lower(requests); return oSequenceObject(s, c, requests, picture, error); }
static BOOL (*oSequencePointer)(id, SEL, NSArray *, void *, NSError **);
static BOOL SequencePointer(id s, SEL c, NSArray *requests, void *picture, NSError **error) { Lower(requests); return oSequencePointer(s, c, requests, picture, error); }
static BOOL (*oSequencePointerOriented)(id, SEL, NSArray *, void *, uint32_t, NSError **);
static BOOL SequencePointerOriented(id s, SEL c, NSArray *requests, void *picture, uint32_t orientation, NSError **error) { Lower(requests); return oSequencePointerOriented(s, c, requests, picture, orientation, error); }

__attribute__((constructor)) static void SaguruVisionLoad(void) {
    if (!getenv("SAGURU_CAM_FOLDER") && !getenv("SAGURU_NET_FOLDER")) return;
    Class image = NSClassFromString(@"VNImageRequestHandler"), sequence = NSClassFromString(@"VNSequenceRequestHandler");
    // An app that does not use Vision has none of this loaded, and nothing is touched.
    if (!image) return;
    Method m = class_getInstanceMethod(image, NSSelectorFromString(@"performRequests:error:"));
    if (m) oImagePerform = (void *)method_setImplementation(m, (IMP)ImagePerform);
    m = class_getInstanceMethod(sequence, NSSelectorFromString(@"performRequests:onCIImage:error:"));
    if (m) oSequenceObject = (void *)method_setImplementation(m, (IMP)SequenceObject);
    m = class_getInstanceMethod(sequence, NSSelectorFromString(@"performRequests:onCVPixelBuffer:error:"));
    if (m) oSequencePointer = (void *)method_setImplementation(m, (IMP)SequencePointer);
    m = class_getInstanceMethod(sequence, NSSelectorFromString(@"performRequests:onCVPixelBuffer:orientation:error:"));
    if (m) oSequencePointerOriented = (void *)method_setImplementation(m, (IMP)SequencePointerOriented);
}
