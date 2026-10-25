//
//  MFImGuiContext.mm — ImGui 上下文（实现）
//
#import "MFImGuiContext.h"
#import <UIKit/UIKit.h>               /* [M5.185] UIScreen.scale（字体密度） */

#include "imgui.h"
#include "imgui_internal.h"           // ImLerp 等
#include "MFImGuiInput.h"
#include "backends/imgui_impl_metal.h"
#import "MFStyle.h"        /* [M5.140] 浅色主题 token（参考项目 ui.h） */
#include <cmath>

@implementation MFImGuiContext {
    ImGuiContext *_ctx;
    BOOL _initialized;
    CFTimeInterval _previousFrameTime;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _queue = [device newCommandQueue];
    }
    return self;
}

#pragma mark - 生命周期

- (BOOL)setupWithError:(NSString **)err {
    if (_initialized) return YES;

    if (!_device || !_queue) {
        if (err) *err = @"Metal device 或 command queue 不可用";
        return NO;
    }

    // 1) 建上下文
    _ctx = ImGui::CreateContext();
    if (!_ctx) {
        if (err) *err = @"ImGui::CreateContext 失败";
        return NO;
    }
    ImGui::SetCurrentContext(_ctx);

    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;                 // iOS 沙箱下 imgui.ini 不可靠（调研 §5.3）
    io.LogFilename = NULL;
    io.ConfigInputTrickleEventQueue = true;

    // 2) Metal 后端
    if (!ImGui_ImplMetal_Init(_device)) {
        if (err) *err = @"ImGui_ImplMetal_Init 失败";
        ImGui::DestroyContext(_ctx);
        _ctx = NULL;
        return NO;
    }

    // 3) 皮肤
    [self applyIOSStyle];

    /*
     * 4) 字体
     * ★ [M5.186] 只用打包的 TrueType 字体 ★
     *
     * 前一版（185）试图改用系统 PingFang.ttc / SFProText.otf，结果 HUD 在
     * 第一帧就没了（hud.log 停在 waiting-for-frames）。
     * 原因：这两者都是 **CFF/OTF 轮廓**，而 ImGui 的栅格器 stb_truetype
     * 只吃 TrueType(glyf) 轮廓 —— 文件能打开、字体对象也能建，但一取字形就崩。
     * 所以回退到打包的 NotoSansSC-subset.ttf，靠 RasterizerDensity 提清晰度。
     */
    if (![self loadFontNamed:@"NotoSansSC-subset" size:15.0f]) {
        NSLog(@"[MF][ImGui] 中文字体加载失败，回退默认字体");
    }

    _initialized = YES;
    [self resetFrameTime];
    NSLog(@"[MF][ImGui] 上下文就绪 (device=%@)", _device.name);
    return YES;
}

- (void)shutdown {
    if (!_initialized) return;
    ImGui::SetCurrentContext(_ctx);
    ImGui_ImplMetal_Shutdown();
    ImGui::DestroyContext(_ctx);
    _ctx = NULL;
    _initialized = NO;
    [self resetFrameTime];
}

#pragma mark - 皮肤

/// iOS 深色风：圆角卡片 + 系统蓝强调 + 克制的分隔线
- (void)applyIOSStyle {
    ImGui::SetCurrentContext(_ctx);
    ImGuiStyle &s = ImGui::GetStyle();
    ImVec4 *c = s.Colors;

    // 尺寸：触屏目标放大
    s.WindowRounding    = 14.0f;
    s.ChildRounding     = 10.0f;
    s.FrameRounding     = 9.0f;
    s.PopupRounding     = 10.0f;
    s.ScrollbarRounding = 9.0f;
    s.GrabRounding      = 9.0f;
    s.TabRounding       = 9.0f;

    s.WindowBorderSize  = 0.0f;
    s.ChildBorderSize   = 0.0f;
    s.FrameBorderSize   = 0.0f;
    s.PopupBorderSize   = 0.0f;

    s.WindowPadding     = ImVec2(14, 12);
    s.FramePadding      = ImVec2(12, 9);       // 触屏要够大
    s.ItemSpacing       = ImVec2(10, 10);
    s.ItemInnerSpacing  = ImVec2(8, 6);
    s.IndentSpacing     = 20.0f;
    s.ScrollbarSize     = 12.0f;
    s.GrabMinSize       = 18.0f;

    s.WindowTitleAlign  = ImVec2(0.5f, 0.5f);
    s.ButtonTextAlign   = ImVec2(0.5f, 0.5f);
    s.SelectableTextAlign = ImVec2(0.0f, 0.5f);
    s.AntiAliasedLines  = true;
    s.AntiAliasedFill   = true;

    // 配色（iOS 深色灰阶 + 系统蓝 #0A84FF / 绿 #30D158 / 红 #FF453A）
    const ImVec4 kBlue   = ImVec4(0.04f, 0.52f, 1.00f, 1.00f);
    const ImVec4 kBlueHi = ImVec4(0.04f, 0.52f, 1.00f, 0.85f);
    const ImVec4 kGreen  = ImVec4(0.19f, 0.82f, 0.35f, 1.00f);

    ImVec4 bg      = ImVec4(0.08f, 0.08f, 0.09f, 0.94f);
    ImVec4 bgChild = ImVec4(0.13f, 0.13f, 0.14f, 1.00f);
    ImVec4 frame   = ImVec4(0.20f, 0.20f, 0.22f, 1.00f);
    ImVec4 text    = ImVec4(1.00f, 1.00f, 1.00f, 1.00f);
    ImVec4 textDim = ImVec4(0.60f, 0.60f, 0.64f, 1.00f);

    c[ImGuiCol_Text]                   = text;
    c[ImGuiCol_TextDisabled]           = textDim;
    c[ImGuiCol_WindowBg]               = bg;
    c[ImGuiCol_ChildBg]                = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_PopupBg]                = bg;
    c[ImGuiCol_Border]                 = ImVec4(1, 1, 1, 0.08f);
    c[ImGuiCol_BorderShadow]           = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_FrameBg]                = frame;
    c[ImGuiCol_FrameBgHovered]         = ImVec4(0.26f, 0.26f, 0.28f, 1.00f);
    c[ImGuiCol_FrameBgActive]          = ImVec4(0.30f, 0.30f, 0.33f, 1.00f);
    c[ImGuiCol_TitleBg]                = ImVec4(0.06f, 0.06f, 0.07f, 1.00f);
    c[ImGuiCol_TitleBgActive]          = ImVec4(0.06f, 0.06f, 0.07f, 1.00f);
    c[ImGuiCol_TitleBgCollapsed]       = ImVec4(0.06f, 0.06f, 0.07f, 0.80f);
    c[ImGuiCol_MenuBarBg]              = ImVec4(0.10f, 0.10f, 0.11f, 1.00f);
    c[ImGuiCol_ScrollbarBg]            = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_ScrollbarGrab]          = ImVec4(1, 1, 1, 0.20f);
    c[ImGuiCol_ScrollbarGrabHovered]   = ImVec4(1, 1, 1, 0.30f);
    c[ImGuiCol_ScrollbarGrabActive]    = ImVec4(1, 1, 1, 0.40f);
    c[ImGuiCol_CheckMark]              = kGreen;
    c[ImGuiCol_SliderGrab]             = kBlue;
    c[ImGuiCol_SliderGrabActive]       = kBlueHi;
    c[ImGuiCol_Button]                 = ImVec4(0.22f, 0.22f, 0.24f, 1.00f);
    c[ImGuiCol_ButtonHovered]          = ImVec4(0.28f, 0.28f, 0.31f, 1.00f);
    c[ImGuiCol_ButtonActive]           = kBlue;
    c[ImGuiCol_Header]                 = ImVec4(0.22f, 0.22f, 0.24f, 1.00f);
    c[ImGuiCol_HeaderHovered]          = ImVec4(0.28f, 0.28f, 0.31f, 1.00f);
    c[ImGuiCol_HeaderActive]           = kBlue;
    c[ImGuiCol_Separator]              = ImVec4(1, 1, 1, 0.08f);
    c[ImGuiCol_SeparatorHovered]       = kBlue;
    c[ImGuiCol_SeparatorActive]        = kBlue;
    c[ImGuiCol_ResizeGrip]             = ImVec4(1, 1, 1, 0.10f);
    c[ImGuiCol_Tab]                    = ImVec4(0.13f, 0.13f, 0.14f, 1.00f);
    c[ImGuiCol_TabHovered]             = ImVec4(0.26f, 0.26f, 0.28f, 1.00f);
    c[ImGuiCol_TabSelected]            = kBlue;
    c[ImGuiCol_TextSelectedBg]         = ImVec4(0.04f, 0.52f, 1.00f, 0.35f);
    c[ImGuiCol_NavHighlight]           = kBlue;
    c[ImGuiCol_ModalWindowDimBg]       = ImVec4(0, 0, 0, 0.55f);

    // 触屏命中盒（调研 §2.4）
    s.TouchExtraPadding = ImVec2(4, 4);

    /* [M5.140] 最后统一换肤：浅色 iOS 主题（覆盖上面的暗色取值） */
    MFApplyLightStyle(&s, MFStyleDefaultOptions());
}

#pragma mark - 字体

/*
 * [M5.185] 系统字体优先。
 * PingFang 是 iOS 的中文正文字体，字形/字重都是用户熟悉的那一套；
 * SFPro 兜英文。两条都读不到就回退打包字体（本 App 走 TrollStore 安装，
 * 没有沙盒限制，正常情况下 PingFang 一定读得到）。
 */
- (BOOL)loadSystemFontAtSize:(float)size density:(float)density {
    ImGui::SetCurrentContext(_ctx);
    static const char *kPaths[] = {
        "/System/Library/Fonts/LanguageSupport/PingFang.ttc",
        "/System/Library/Fonts/LanguageSupport/PingFangSC-Regular.ttf",
        "/System/Library/Fonts/Core/SFProText-Regular.otf",
        "/System/Library/Fonts/Core/SFUI.ttf",
        "/System/Library/Fonts/Core/SFUISans.ttf",
    };

    NSFileManager *fm = [NSFileManager defaultManager];
    ImGuiIO &io = ImGui::GetIO();
    for (size_t i = 0; i < sizeof(kPaths) / sizeof(kPaths[0]); i++) {
        NSString *path = [NSString stringWithUTF8String:kPaths[i]];
        if (![fm isReadableFileAtPath:path]) continue;

        ImFontConfig cfg;
        cfg.RasterizerDensity = density;    /* ★ 2x/3x 烘焙 → 不糊 */
        cfg.FontNo = 0;                     /* TTC 取第一个字面（PingFangSC） */
        cfg.PixelSnapH = false;
        ImFont *f = io.Fonts->AddFontFromFileTTF(path.fileSystemRepresentation, size, &cfg);
        if (f != NULL) {
            io.FontDefault = f;
            NSLog(@"[MF][ImGui] 系统字体已加载: %@ @ %.0fpt density=%.1f",
                  path.lastPathComponent, size, density);
            return YES;
        }
    }
    NSLog(@"[MF][ImGui] 系统字体都读不到，回退打包字体");
    return NO;
}

- (BOOL)loadFontNamed:(NSString *)name size:(float)size {
    ImGui::SetCurrentContext(_ctx);
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"ttf"];
    if (!path) path = [[NSBundle mainBundle] pathForResource:name ofType:@"otf"];
    if (!path) {
        NSLog(@"[MF][ImGui] 找不到字体资源: %@", name);
        return NO;
    }

    ImGuiIO &io = ImGui::GetIO();
    // 1.92+ 动态字体：不传 GlyphRanges、不 Build()
    ImFontConfig cfg;
    cfg.RasterizerDensity = (float)MAX(2.0, (double)(UIScreen.mainScreen.scale ?: 2.0));
    ImFont *f = io.Fonts->AddFontFromFileTTF(path.fileSystemRepresentation, size, &cfg);
    if (!f) {
        NSLog(@"[MF][ImGui] AddFontFromFileTTF 返回空: %@", path);
        return NO;
    }
    io.FontDefault = f;
    NSLog(@"[MF][ImGui] 字体已加载: %@ @ %.0fpt", path.lastPathComponent, size);
    return YES;
}

#pragma mark - 每帧

- (void)resetFrameTime {
    _previousFrameTime = 0;
}

- (void)discardFrame {
    if (!_initialized) return;
    ImGui::SetCurrentContext(_ctx);
    if (_ctx->WithinFrameScope) ImGui::EndFrame();
}

- (void)beginFrameWithSize:(CGSize)size
                     scale:(CGFloat)scale
                descriptor:(MTLRenderPassDescriptor *)descriptor {
    ImGui::SetCurrentContext(_ctx);
    ImGuiIO &io = ImGui::GetIO();
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = now - _previousFrameTime;
    io.DeltaTime = (_previousFrameTime > 0 && elapsed > 0 && std::isfinite(elapsed))
        ? (float)elapsed : 1.0f / 60.0f;
    _previousFrameTime = now;
    io.DisplaySize = ImVec2((float)size.width, (float)size.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);

    ImGui_ImplMetal_NewFrame(descriptor);
    ImGui::NewFrame();
}

- (void)buildUI:(void (^)(void))block {
    ImGui::SetCurrentContext(_ctx);
    if (block) block();
}

- (void)endFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          encoder:(id<MTLRenderCommandEncoder>)encoder {
    ImGui::SetCurrentContext(_ctx);
    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
}

#pragma mark - 输入

- (void)addTouchX:(float)x y:(float)y down:(BOOL)down {
    if (!_initialized) return;
    ImGui::SetCurrentContext(_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent(x, y);
    io.AddMouseButtonEvent(0, down);
}

- (void)cancelTouch {
    if (!_initialized) return;
    ImGui::SetCurrentContext(_ctx);
    MFCancelImGuiTouch();
}

- (void)addScrollY:(float)dy {
    ImGui::SetCurrentContext(_ctx);
    ImGui::GetIO().AddMouseWheelEvent(0.0f, dy);
}

- (void)addFocus:(BOOL)focused {
    ImGui::SetCurrentContext(_ctx);
    ImGui::GetIO().AddFocusEvent(focused);
}

- (BOOL)wantsTouch {
    ImGui::SetCurrentContext(_ctx);
    return ImGui::GetIO().WantCaptureMouse;
}

@end
