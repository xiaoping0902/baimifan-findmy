#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import "MFDrawingLayer.h"
#import "MFGameReader.h"
#import "MFUEReader.h"
#import "MFSettings.h"
#import "../app/Sources/Read/MFExternalFeed.h"
#import "../app/Sources/Read/MFReadBackend.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Render/imgui/imgui.h"
#include "HUDRegressionOutput.h"
#include <cmath>
#include <cstring>

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)

// Declare the existing delegate entry point without replacing its implementation.
@interface MFDrawingLayer (RegressionEntryPoint)
- (void)overlayBuildUI:(MFImGuiContext *)context overlay:(MFOverlayView *)overlay;
@end

// This fixture tests only synthetic UDP -> production drawing -> ImGui DrawData.
// It does not attach to a game or establish that real game data can be rendered.
// Keep readiness and the renderer real, but fail at the external memory boundary
// if any production path unexpectedly attempts a remote read.
static BOOL RejectRemoteRead(id object, SEL selector, uint64_t address, void *out, size_t size) {
    CHECK(NO, "synthetic drawing regression must not attempt any remote memory read");
    return NO;
}

static ImDrawData *Frame(MFDrawingLayer *drawing, MFOverlayView *overlay) {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(640, 720);
    io.DeltaTime = 1.0f / 60.0f;
    ImGui::NewFrame();
    [drawing overlayBuildUI:nil overlay:overlay];
    ImGui::Render();
    return ImGui::GetDrawData();
}

static void SendSyntheticFrame(uint16_t port) {
    // Hand-written little-endian protocol fixture, independent of production
    // decode: 44-byte header + one 20-byte entity. Camera at origin faces +X
    // with FOV 90; a live non-bot person at (1000, 0, 0) is centered and 10m away.
    uint8_t packet[64] = {};
    const uint32_t magic = 0x4446464D, count = 1, sequence = 73, flags = 1;
    const uint16_t version = 1, headerSize = 44;
    const float camera[6] = {0, 0, 0, 0, 0, 90};
    const float entity[3] = {1000, 0, 0};
    memcpy(packet + 0, &magic, sizeof(magic));
    memcpy(packet + 4, &version, sizeof(version));
    memcpy(packet + 6, &headerSize, sizeof(headerSize));
    memcpy(packet + 8, &count, sizeof(count));
    memcpy(packet + 12, &sequence, sizeof(sequence));
    memcpy(packet + 16, camera, sizeof(camera));
    memcpy(packet + 40, &flags, sizeof(flags));
    memcpy(packet + 44, entity, sizeof(entity));
    packet[58] = 1; // kind=person; bot, dead, padding and classId remain zero.

    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(sender >= 0, "synthetic UDP sender socket must open");
    struct sockaddr_in destination = {};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(port);
    destination.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ssize_t sent = sendto(sender, packet, sizeof(packet), 0,
                          (struct sockaddr *)&destination, sizeof(destination));
    close(sender);
    CHECK(sent == (ssize_t)sizeof(packet), "complete synthetic datagram must reach the loopback socket");
}

static void TestExternalFeedWithoutLocalReadiness(void) {
    MFGameReader *reader = [MFGameReader shared];
    reader.targetTaskPort = MACH_PORT_NULL;
    reader.rootObjectBase = reader.entityArrayBase = reader.lootArrayBase = 0;
    [MFUEReader shared].libBase = 0;
    CHECK(!reader.ready && ![MFReadBackend shared].gateOpen,
          "synthetic fixture must begin with no local reader readiness or target port");

    Method remoteRead = class_getInstanceMethod(MFReadBackend.class, @selector(readRemote:into:size:));
    CHECK(remoteRead != NULL, "production memory boundary must exist for the fail-fast guard");
    IMP originalRemoteRead = method_setImplementation(remoteRead, (IMP)RejectRemoteRead);

    MFSettings *settings = [MFSettings shared];
    [settings resetToDefaults];
    settings.masterEnabled = settings.drawEnabled = YES;
    settings.renderSelfTest = NO; // The synthetic packet, not runSelfTest:, must supply the content.
    settings.showName = settings.showArmor = settings.showHealth = NO;
    settings.showDistance = settings.showTeam = NO;
    [MFDrawingLayer setEnabled:YES];

    MFExternalFeed *feed = [MFExternalFeed shared];
    CHECK(!feed.running && feed.packetCount == 0,
          "drawing must start the real receiver rather than rely on a prestarted feed");
    MFOverlayView *overlay = [[MFOverlayView alloc] initWithFrame:CGRectMake(0, 0, 640, 720)
                                                               interactive:NO];
    overlay.automaticallyStartsRendering = NO;
    MFDrawingLayer *drawing = [MFDrawingLayer new];
    drawing.overlay = overlay;

    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    unsigned char *pixels;
    int fontWidth, fontHeight;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &fontWidth, &fontHeight);

    ImDrawData *empty = Frame(drawing, overlay);
    CHECK(empty->TotalVtxCount == 0 && !drawing.lastCameraOK,
          "no received synthetic frame must produce no drawing content");
    printf("TRACE: local_ready=%d libBase=%llu feed_running=%d vertices_before_packet=%d\n",
           reader.ready, (unsigned long long)[MFUEReader shared].libBase,
           feed.running, empty->TotalVtxCount);
    CHECK(feed.running,
          "drawing must start the external feed even when local reader is not ready and libBase is zero");

    SendSyntheticFrame(feed.port);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (feed.packetCount == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    CHECK(feed.packetCount == 1 && feed.errorCount == 0 && feed.lastSequence == 73 && feed.fresh,
          "real UDP receiver must decode the complete synthetic frame before rendering");
    ImDrawData *drawData = Frame(drawing, overlay);
    CHECK(drawing.lastCameraOK && drawing.lastEntityCount == 1 && drawing.lastLootCount == 0,
          "production drawing must consume the synthetic camera and entity with local readiness still false");
    CHECK(drawData->CmdLists.Size > 0 && drawData->TotalVtxCount >= 4 && drawData->TotalIdxCount >= 6,
          "the received synthetic frame must generate actual nonempty ImGui drawing commands");
    BOOL visibleVertex = NO;
    for (int list = 0; list < drawData->CmdLists.Size; list++) {
        for (const ImDrawVert &vertex : drawData->CmdLists[list]->VtxBuffer) {
            CHECK(std::isfinite(vertex.pos.x) && std::isfinite(vertex.pos.y),
                  "synthetic frame drawing coordinates must remain finite");
            if (vertex.pos.x > 0 && vertex.pos.x < 640 && vertex.pos.y > 0 && vertex.pos.y < 720 &&
                (vertex.col & IM_COL32_A_MASK) != 0) visibleVertex = YES;
        }
    }
    CHECK(visibleVertex, "synthetic frame must generate a nontransparent vertex inside the logical screen");
    CHECK(!reader.ready && [MFUEReader shared].libBase == 0 && ![MFReadBackend shared].gateOpen,
          "drawing synthetic feed data must not require enabling local memory access");
    printf("TRACE: synthetic_udp_packets=%lu entities=%lu vertices=%d indices=%d\n",
           (unsigned long)feed.packetCount, (unsigned long)drawing.lastEntityCount,
           drawData->TotalVtxCount, drawData->TotalIdxCount);
    [feed stop];
    ImGui::DestroyContext();
    method_setImplementation(remoteRead, originalRemoteRead);
}

@interface DrawingRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation DrawingRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            TestExternalFeedWithoutLocalReadiness();
            puts("PASS: production drawing consumes synthetic UDP without local reader readiness (no game data)");
            exit(0);
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: synthetic drawing regression raised %s: %s\n",
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
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(DrawingRegressionDelegate.class));
    }
}
