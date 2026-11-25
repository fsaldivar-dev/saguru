// SimuruAgent: loaded into an app running in the iOS Simulator (never part of the app itself).
// It watches the app's URLSession traffic and can answer chosen requests with a saved response.
//
// It talks to Simuru through a folder on the Mac, which the simulator shares:
//   events.jsonl   one JSON object per line, written here: a request starting, a request ending
//   <id>.req/.res  the bodies, as files, so images and other binaries travel untouched
//   mocks.json     written by Simuru: the responses to give instead of going to the network
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *gFolder;
static dispatch_queue_t gWriter;
static NSString *const kHandled = @"dev.simuru.handled";
static const NSUInteger kStoredBodyLimit = 8 * 1024 * 1024;

static void Emit(NSDictionary *event) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!json) return;
    dispatch_async(gWriter, ^{
        NSString *path = [gFolder stringByAppendingPathComponent:@"events.jsonl"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:json];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

static NSString *SaveBody(NSData *data, NSString *identifier, NSString *suffix) {
    if (data.length == 0) return nil;
    NSString *path = [gFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", identifier, suffix]];
    NSData *stored = data.length > kStoredBodyLimit ? [data subdataWithRange:NSMakeRange(0, kStoredBodyLimit)] : data;
    return [stored writeToFile:path atomically:YES] ? path : nil;
}

/// The URL without its query: what a mock is matched against.
static NSString *Route(NSURL *url) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    parts.query = nil;
    parts.fragment = nil;
    return parts.string ?: url.absoluteString;
}

/// The mock for a request, if Simuru has one enabled. The file is read again whenever it changes.
static NSDictionary *MockFor(NSURLRequest *request) {
    static NSArray *mocks;
    static NSDate *loaded;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSString *path = [gFolder stringByAppendingPathComponent:@"mocks.json"];
        NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (modified && ![modified isEqualToDate:loaded]) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            mocks = [parsed isKindOfClass:NSArray.class] ? parsed : @[];
            loaded = modified;
        }
        NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
        NSString *route = Route(request.URL);
        for (NSDictionary *mock in mocks) {
            if ([mock[@"method"] isEqual:method] && [mock[@"url"] isEqual:route]) return mock;
        }
        return nil;
    }
}

@interface SimuruURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@end

@implementation SimuruURLProtocol {
    NSURLSession *_session;
    NSString *_identifier;
    NSDate *_started;
    NSMutableData *_received;
    NSUInteger _receivedLength;
    NSHTTPURLResponse *_response;
    NSDictionary *_sent;
    NSString *_protocol;
    BOOL _stopped;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    // A request this agent is already carrying must go to the network, not back in here.
    return [NSURLProtocol propertyForKey:kHandled inRequest:request] == nil;
}

+ (BOOL)canInitWithTask:(NSURLSessionTask *)task {
    // Only plain data-style tasks: streams and web sockets are left alone.
    if ([task isKindOfClass:NSClassFromString(@"NSURLSessionStreamTask")] || [task isKindOfClass:NSClassFromString(@"NSURLSessionWebSocketTask")]) return NO;
    return task.currentRequest ? [self canInitWithRequest:task.currentRequest] : NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    _identifier = NSUUID.UUID.UUIDString;
    _started = [NSDate date];
    _received = [NSMutableData data];

    NSMutableURLRequest *request = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:request];
    // URLSession hands the body over as a stream; it has to be read here to be seen, and put back to be sent.
    NSData *body = request.HTTPBody;
    if (!body && request.HTTPBodyStream) {
        NSInputStream *stream = request.HTTPBodyStream;
        NSMutableData *read = [NSMutableData data];
        [stream open];
        uint8_t buffer[16384];
        NSInteger count;
        while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [read appendBytes:buffer length:(NSUInteger)count];
        [stream close];
        body = read;
        request.HTTPBody = read;
    }

    NSMutableDictionary *start = [@{
        @"phase": @"start", @"id": _identifier, @"method": request.HTTPMethod ?: @"GET", @"url": request.URL.absoluteString ?: @"",
        @"headers": request.allHTTPHeaderFields ?: @{}, @"size": @(body.length), @"time": @(_started.timeIntervalSince1970),
    } mutableCopy];
    NSString *saved = SaveBody(body, _identifier, @"req");
    if (saved) start[@"body"] = saved;
    Emit(start);

    NSDictionary *mock = MockFor(request);
    if (mock) {
        double delay = [mock[@"delay"] doubleValue] / 1000.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self answerWithMock:mock];
        });
        return;
    }
    _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:self delegateQueue:nil];
    [[_session dataTaskWithRequest:request] resume];
}

- (void)answerWithMock:(NSDictionary *)mock {
    @synchronized (self) { if (_stopped) return; }
    NSData *body = mock[@"body"] ? [NSData dataWithContentsOfFile:mock[@"body"]] : nil;
    NSDictionary *headers = [mock[@"headers"] isKindOfClass:NSDictionary.class] ? mock[@"headers"] : @{};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:[mock[@"status"] integerValue]
                                                             HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length) [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
    _response = response;
    _receivedLength = body.length;
    [_received setData:body ?: [NSData data]];
    [self reportEnd:nil mocked:YES];
}

- (void)stopLoading {
    @synchronized (self) { _stopped = YES; }
    [_session invalidateAndCancel];
    _session = nil;
}

- (void)reportEnd:(NSError *)error mocked:(BOOL)mocked {
    NSMutableDictionary *end = [@{
        @"phase": @"end", @"id": _identifier, @"duration": @(-_started.timeIntervalSinceNow), @"size": @(_receivedLength), @"mocked": @(mocked),
    } mutableCopy];
    if (_response) {
        end[@"status"] = @(_response.statusCode);
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        [_response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) { headers[[key description]] = [value description]; }];
        end[@"headers"] = headers;
        if (_response.MIMEType) end[@"mime"] = _response.MIMEType;
    }
    // The headers that really went out: the app's own plus the ones the system adds (User-Agent, Accept…).
    if (_sent.count) end[@"sent"] = _sent;
    if (_protocol) end[@"protocol"] = _protocol;
    if (error) end[@"error"] = error.localizedDescription ?: @"Error";
    NSString *saved = SaveBody(_received, _identifier, @"res");
    if (saved) end[@"body"] = saved;
    Emit(end);
}

// MARK: The real request, carried on the app's behalf

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) _response = (NSHTTPURLResponse *)response;
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
    _receivedLength += data.length;
    if (_received.length < kStoredBodyLimit) [_received appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    _sent = metrics.transactionMetrics.lastObject.request.allHTTPHeaderFields;
    _protocol = metrics.transactionMetrics.lastObject.networkProtocolName;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) [self.client URLProtocol:self didFailWithError:error];
    else [self.client URLProtocolDidFinishLoading:self];
    // A cancelled request was cancelled by the app itself; it is still worth showing.
    [self reportEnd:error mocked:NO];
    [session finishTasksAndInvalidate];
}

@end

// MARK: Installing

static void Include(NSURLSessionConfiguration *configuration) {
    NSMutableArray *classes = [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![classes containsObject:SimuruURLProtocol.class]) {
        [classes insertObject:SimuruURLProtocol.class atIndex:0];
        configuration.protocolClasses = classes;
    }
}

static NSURLSessionConfiguration *(*gDefault)(id, SEL);
static NSURLSessionConfiguration *(*gEphemeral)(id, SEL);
static NSURLSessionConfiguration *DefaultConfiguration(id self, SEL _cmd) { NSURLSessionConfiguration *c = gDefault(self, _cmd); Include(c); return c; }
static NSURLSessionConfiguration *EphemeralConfiguration(id self, SEL _cmd) { NSURLSessionConfiguration *c = gEphemeral(self, _cmd); Include(c); return c; }

__attribute__((constructor)) static void SimuruAgentLoad(void) {
    const char *folder = getenv("SIMURU_NET_FOLDER");
    if (!folder) return;
    gFolder = [NSString stringWithUTF8String:folder];
    gWriter = dispatch_queue_create("dev.simuru.agent", DISPATCH_QUEUE_SERIAL);
    // URLSession.shared and anything using the registered protocols.
    [NSURLProtocol registerClass:SimuruURLProtocol.class];
    // Sessions created with their own configuration: the configuration is handed out with this agent in it.
    Class meta = object_getClass(NSURLSessionConfiguration.class);
    Method method = class_getInstanceMethod(meta, @selector(defaultSessionConfiguration));
    gDefault = (void *)method_setImplementation(method, (IMP)DefaultConfiguration);
    method = class_getInstanceMethod(meta, @selector(ephemeralSessionConfiguration));
    gEphemeral = (void *)method_setImplementation(method, (IMP)EphemeralConfiguration);
    Emit(@{@"phase": @"hello", @"app": NSBundle.mainBundle.bundleIdentifier ?: @"", @"time": @(NSDate.date.timeIntervalSince1970)});
}
