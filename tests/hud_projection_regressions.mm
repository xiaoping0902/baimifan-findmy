#import <UIKit/UIKit.h>
#import "MFProjection.h"
#include <cmath>
#include <limits>
#include <stdio.h>
#include <stdlib.h>
#include "HUDRegressionOutput.h"

// Exercise the public Objective-C API and the production MFProjection.mm.
// All coordinates are synthetic; this fixture does not open a game process.
static int failures = 0;
static int checks = 0;

static void Check(BOOL condition, const char *message) {
    ++checks;
    if (!condition) {
        ++failures;
        fprintf(stderr, "FAIL: %s\n", message);
    }
}

static void CheckPoint(MFPoint2D point, float x, float y, const char *message) {
    BOOL matches = point.valid && std::isfinite(point.x) && std::isfinite(point.y) &&
                   fabsf(point.x - x) < 0.01f && fabsf(point.y - y) < 0.01f;
    if (!matches) {
        fprintf(stderr, "TRACE: %s actual=(%.6f,%.6f) valid=%d expected=(%.6f,%.6f)\n",
                message, point.x, point.y, point.valid, x, y);
    }
    Check(matches, message);
}

static void CheckRejected(MFPoint2D point, const char *message) {
    Check(!point.valid && point.x == -9999.0f && point.y == -9999.0f, message);
}

static MFCamera Camera(void) {
    MFCamera camera = {};
    camera.fov = 90.0f;
    return camera;
}

static MFPoint2D Project(float x, float y, float z, MFCamera camera, MFScreen screen) {
    const float target[] = {x, y, z};
    return [MFProjection projectTarget:target camera:camera screen:screen];
}

static void TestHorizontalFOVAndDefaultAxes(void) {
    MFCamera camera = Camera();
    MFScreen screen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov];
    CheckPoint(Project(100, 0, 0, camera, screen), 400, 300,
               "a forward target must project to the screen center");
    // A 90 degree horizontal field of view puts +/-45 degree rays at x=0/800.
    CheckPoint(Project(100, 100, 0, camera, screen), 800, 300,
               "90 degree FOV must put a +45 degree ray at the right edge");
    CheckPoint(Project(100, -100, 0, camera, screen), 0, 300,
               "90 degree FOV must put a -45 degree ray at the left edge");
    CheckPoint(Project(100, 50, 25, camera, screen), 600, 200,
               "positive UE right/up must move right/up using one horizontal focal length");
    CheckPoint(Project(100, 0, 100, camera, screen), 400, -100,
               "vertical projection must use the horizontal FOV scale even on a nonsquare screen");

    camera.fov = 60;
    screen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov];
    CheckPoint(Project(100, 57.7350269f, 0, camera, screen), 800, 300,
               "60 degree horizontal FOV must put a +30 degree ray at the right edge");
    camera.fov = 120;
    screen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov];
    CheckPoint(Project(100, 173.205081f, 0, camera, screen), 800, 300,
               "120 degree horizontal FOV must put a +60 degree ray at the right edge");
}

static void TestDepthResolutionAndCameraPose(void) {
    MFCamera camera = Camera();
    MFScreen screen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov];
    CheckPoint(Project(100, 25, 10, camera, screen), 500, 260,
               "a near target must have the hand-derived perspective displacement");
    CheckPoint(Project(200, 25, 10, camera, screen), 450, 280,
               "doubling depth must halve displacement from the screen center");
    MFScreen doubled = [MFProjection screenWithSize:CGSizeMake(1600, 1200) fov:camera.fov];
    CheckPoint(Project(100, 25, 10, camera, doubled), 1000, 520,
               "doubling logical screen dimensions must double projected coordinates");

    camera.x = 10; camera.y = 20; camera.z = 30; camera.yaw = 90;
    CheckPoint(Project(10, 120, 30, camera, screen), 400, 300,
               "camera translation and a 90 degree yaw must preserve the forward center");
    CheckPoint(Project(-90, 120, 30, camera, screen), 800, 300,
               "a yawed camera must preserve the UE right-axis orientation");
    camera = Camera();
    camera.pitch = 30;
    CheckPoint(Project(86.6025404f, 0, 50, camera, screen), 400, 300,
               "a target on a pitched forward ray must remain at screen center");
}

static void TestExplicitSignAndRollControls(void) {
    MFProjection *projection = [MFProjection new];
    MFCamera camera = Camera();
    MFScreen screen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov];
    const float target[] = {100, 50, 25};
    projection.convention = (MFSignConvention){ .negateSide = YES, .negateUp = NO, .applyRoll = NO };
    CheckPoint([projection projectTarget:target camera:camera screen:screen], 200, 200,
               "an explicit horizontal sign override must still mirror the projection");
    projection.convention = (MFSignConvention){ .negateSide = NO, .negateUp = YES, .applyRoll = NO };
    CheckPoint([projection projectTarget:target camera:camera screen:screen], 600, 400,
               "an explicit vertical sign override must still mirror the projection");
    projection.convention = (MFSignConvention){ .negateSide = NO, .negateUp = NO, .applyRoll = YES };
    camera.roll = 90;
    CheckPoint([projection projectTarget:target camera:camera screen:screen], 500, 500,
               "the explicit roll option must still rotate the screen-plane components");
}

static void TestRejectInvalidInputs(void) {
    MFCamera camera = Camera();
    MFScreen screen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov];
    CheckRejected(Project(-100, 0, 0, camera, screen), "a target behind the camera must be rejected");
    CheckRejected(Project(0.05f, 0, 0, camera, screen), "a target inside the near-depth threshold must be rejected");
    CheckRejected([MFProjection projectTarget:nullptr camera:camera screen:screen], "a null target must be rejected");
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float infinity = std::numeric_limits<float>::infinity();
    const float badFOVs[] = {0, -1, 180, 181, nan, infinity};
    for (float badFOV : badFOVs) {
        MFCamera invalid = camera;
        invalid.fov = badFOV;
        MFScreen invalidScreen = [MFProjection screenWithSize:CGSizeMake(800, 600) fov:badFOV];
        CheckRejected(Project(100, 50, 25, invalid, invalidScreen),
                      "a nonfinite or out-of-range FOV must reject projection rather than invent a fallback");
    }
    const CGSize badSizes[] = {CGSizeMake(0, 600), CGSizeMake(800, 0),
                              CGSizeMake(-1, 600), CGSizeMake(800, -1),
                              CGSizeMake(nan, 600), CGSizeMake(800, infinity)};
    for (CGSize badSize : badSizes) {
        MFScreen invalidScreen = [MFProjection screenWithSize:badSize fov:camera.fov];
        CheckRejected(Project(100, 50, 25, camera, invalidScreen),
                      "zero, negative or nonfinite screen dimensions must reject projection");
    }
    const float badValues[] = {nan, infinity, -infinity};
    for (float bad : badValues) {
        CheckRejected(Project(100, bad, 25, camera, screen), "a nonfinite target side must be rejected");
        CheckRejected(Project(100, 50, bad, camera, screen), "a nonfinite target height must be rejected");
        MFCamera invalid = camera;
        invalid.x = bad;
        CheckRejected(Project(100, 50, 25, invalid, screen), "a nonfinite camera position must be rejected");
        invalid = camera;
        invalid.pitch = bad;
        CheckRejected(Project(100, 50, 25, invalid, screen), "a nonfinite camera pitch must be rejected");
        invalid = camera;
        invalid.yaw = bad;
        CheckRejected(Project(100, 50, 25, invalid, screen), "a nonfinite camera yaw must be rejected");
        invalid = camera;
        invalid.roll = bad;
        CheckRejected(Project(100, 50, 25, invalid, screen), "a nonfinite camera roll must be rejected even when roll is disabled");
        MFScreen invalidScreen = screen;
        invalidScreen.focal = bad;
        CheckRejected(Project(100, 50, 25, camera, invalidScreen), "a nonfinite screen focal length must be rejected");
        invalidScreen = screen;
        invalidScreen.centerX = bad;
        CheckRejected(Project(100, 50, 25, camera, invalidScreen), "a nonfinite screen center must be rejected");
    }
    // Finite input is not enough if perspective multiplication overflows.
    CheckRejected(Project(1, std::numeric_limits<float>::max(), 0, camera, screen),
                  "an overflowing projected coordinate must never be marked valid");
}

@interface ProjectionRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProjectionRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            TestHorizontalFOVAndDefaultAxes();
            TestDepthResolutionAndCameraPose();
            TestExplicitSignAndRollControls();
            TestRejectInvalidInputs();
            printf("TRACE: production projection checks=%d failures=%d\n", checks, failures);
            if (failures) exit(1);
            puts("PASS: production projection geometry and invalid-input rejection");
            exit(0);
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: production projection raised %s: %s\n",
                    exception.name.UTF8String, exception.reason.UTF8String);
            exit(1);
        }
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProjectionRegressionDelegate.class));
    }
}
