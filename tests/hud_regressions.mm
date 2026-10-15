#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>

// Private iOS services are unavailable on the macOS runner. Only those service
// boundaries are replaced; context ownership, retries and report validation run
// the same production Objective-C implementations used by the iPad app.
#if __has_include("MFHUDWindowHost.h")
#import "MFHUDWindowHost.h"
#import "MFHUDStartupStatus.h"
#else
@interface MFHUDWindowHost : NSObject
@property (readonly) uint32_t contextID;
@property (readonly) id context;
@property (readonly) id hostingController;
- (instancetype)initWithLayer:(CALayer *)layer nativeContextID:(uint32_t)cid
                        level:(double)level contextClass:(Class)cc hostingClass:(Class)hc;
- (BOOL)registerWithError:(NSString **)error;
@end
typedef NS_ENUM(NSInteger, MFHUDStartupState) {
    MFHUDStartupPending, MFHUDStartupReady, MFHUDStartupFailed, MFHUDStartupExited
};
@interface MFHUDStartupStatus : NSObject
+ (MFHUDStartupState)stateForReport:(NSDictionary *)report pid:(int)pid
                            token:(NSString *)token processAlive:(BOOL)alive;
@end
#endif

#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

static unsigned creations, registrations;
static BOOL zeroID, throwOnRegister;
@interface FakeRemoteContext : NSObject
@property (strong) CALayer *layer;
@property BOOL secure;
@property (readonly) uint32_t contextId;
+ (id)remoteContextWithOptions:(NSDictionary *)options;
@end
@implementation FakeRemoteContext
+ (id)remoteContextWithOptions:(NSDictionary *)options { creations++; return [self new]; }
- (uint32_t)contextId { return zeroID ? 0 : 0x1234abcd; }
@end

@interface FakeHostingController : NSObject
- (void)registerWindowWithContextID:(unsigned)cid atLevel:(double)level;
@end
@implementation FakeHostingController
- (void)registerWindowWithContextID:(unsigned)cid atLevel:(double)level {
    if (throwOnRegister) [NSException raise:@"ServiceUnavailable" format:@"test registration failure"];
    CHECK(cid == 0x1234abcd || cid == 77, "registration must use the context that owns the layer");
    CHECK(level == 10000009.0, "window level must survive the private API boundary");
    registrations++;
}
@end

static MFHUDWindowHost *NewHost(uint32_t nativeID) {
    Class cls = NSClassFromString(@"MFHUDWindowHost");
    CHECK(cls != Nil, "window context/hosting lifetime owner is missing");
    return [[cls alloc] initWithLayer:[CALayer layer] nativeContextID:nativeID
                               level:10000009.0 contextClass:[FakeRemoteContext class]
                        hostingClass:[FakeHostingController class]];
}

static void TestSingleContextAndControllerLifetime(void) {
    creations = registrations = 0;
    __weak id weakController;
    @autoreleasepool {
        MFHUDWindowHost *host = NewHost(0);
        NSString *error = nil;
        CHECK([host registerWithError:&error], "valid remote context should register");
        CHECK(host.contextID == 0x1234abcd, "host must expose its registered ID");
        CHECK(((FakeRemoteContext *)host.context).layer != nil, "remote context must retain the layer tree");
        CHECK([host registerWithError:&error], "repeated registration should be idempotent");
        CHECK(creations == 1 && registrations == 1, "a window must not create or register two contexts");
        weakController = host.hostingController;
        CHECK(weakController != nil, "hosting controller must outlive the registration call");
    }
    CHECK(weakController == nil, "hosting owner must release the service controller when destroyed");
}

static void TestNativeAndFailurePaths(void) {
    creations = registrations = 0;
    MFHUDWindowHost *native = NewHost(77);
    CHECK([native registerWithError:NULL], "native context should register");
    CHECK(creations == 0 && native.context == nil && registrations == 1,
          "a native UIKit context must not be replaced with a remote context");

    zeroID = YES;
    MFHUDWindowHost *invalid = NewHost(0);
    NSString *error = nil;
    CHECK(![invalid registerWithError:&error] && error.length > 0,
          "zero context ID must produce an actionable failure");
    CHECK(registrations == 1, "zero context ID must never reach SpringBoard registration");
    zeroID = NO;

    MFHUDWindowHost *retry = NewHost(0);
    throwOnRegister = YES;
    CHECK(![retry registerWithError:&error] && error.length > 0,
          "private registration exceptions must be reported");
    CHECK(retry.hostingController == nil, "failed registration must not leave a successful host");
    unsigned before = creations;
    throwOnRegister = NO;
    CHECK([retry registerWithError:&error], "registration can retry after service failure");
    CHECK(creations == before, "retry must reuse the context that already owns the layer");
}

static void TestReadinessIsNotProcessLiveness(void) {
    Class status = NSClassFromString(@"MFHUDStartupStatus");
    CHECK(status != Nil, "startup report validation is missing");
    CHECK([status stateForReport:nil pid:42 token:@"new" processAlive:YES] == MFHUDStartupPending,
          "a living process without frames is not ready");
    NSMutableDictionary *r = [@{ @"pid": @42, @"token": @"new", @"state": @"ready",
                                 @"menuContextID": @77, @"drawingContextID": @88,
                                 @"menuRegistered": @YES, @"drawingRegistered": @YES,
                                 @"menuFrame": @YES, @"drawingFrame": @YES } mutableCopy];
    CHECK([status stateForReport:r pid:42 token:@"new" processAlive:YES] == MFHUDStartupReady,
          "both registered windows and completed frames should report ready");
    CHECK([status stateForReport:r pid:42 token:@"old" processAlive:YES] == MFHUDStartupPending,
          "a stale launch token must not report success");
    CHECK([status stateForReport:r pid:43 token:@"new" processAlive:YES] == MFHUDStartupPending,
          "another process report must not report success");
    r[@"drawingFrame"] = @NO;
    CHECK([status stateForReport:r pid:42 token:@"new" processAlive:YES] == MFHUDStartupPending,
          "one completed frame must not hide failure in the other window");
    r[@"state"] = @"failed";
    CHECK([status stateForReport:r pid:42 token:@"new" processAlive:YES] == MFHUDStartupFailed,
          "explicit child failure must reach the launcher");
    CHECK([status stateForReport:r pid:42 token:@"new" processAlive:NO] == MFHUDStartupExited,
          "an exited process must never be ready");
}

int main(void) {
    @autoreleasepool {
        TestSingleContextAndControllerLifetime();
        TestNativeAndFailurePaths();
        TestReadinessIsNotProcessLiveness();
        puts("PASS: HUD ownership, retries, native/remote contexts and launch readiness");
    }
    return 0;
}
