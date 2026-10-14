# ImGui iOS / Metal 集成调研报告

> 面向：**白米饭复刻**项目（目标机 iOS 16.6.1 / iPad / TrollStore 安装 / GitHub Actions macOS runner 云构建）
> 报告日期：2026-10-14（北京时间）
> 证据基础：除明确标注【推断】【未证】外，所有【已证】结论均直接核对自本地克隆的源码与仓库内官方文档。引用格式 `文件:行号`，行号对应当前 commit（个别 ± 几行偏差属正常）。

---

## 克隆信息（报告开头）

| 项 | 值 |
|---|---|
| 上游仓库 | `https://github.com/ocornut/imgui.git`（默认 master 分支） |
| **克隆时 commit** | **`098c71133c32b7b946ae2b6db27fc8a4d0629d68`** |
| commit 日期 / 标题 | 2026-10-13 16:38:13 +0200 · `Demo: Plot, Vertical Sliders, Colors: better scaling.` |
| 版本号 | `1.93.0 WIP`（`IMGUI_VERSION_NUM = 19298`）（imgui.h:32-33） |
| 克隆方式 | `git clone --depth 1`（浅克隆），直连 github.com 成功（未用 `gh-proxy.com` 镜像）；**克隆后 `.git` 已删除**，仅保留源码文件 |
| 本地路径 | `C:/Users/xiaoping/Desktop/白米饭复刻/app/Sources/Render/imgui/` |
| 规模 | 304 个文件 / 8.8 MB（含 `backends/`、`examples/`、`docs/`、`misc/`） |
| 升级提示 | `.git` 已删，后续升级需重新克隆；注意 1.92（2025-06）起字体系统/API 有重大变化（见 §3、§4），跨版本升级请先读 `docs/Changelog.txt` |

### 标注体系（全文通用）

- 【已证】：已直接核对克隆源码 / 仓库内官方文档（给出 `文件:行号`）。
- 【推断】：基于已证事实与平台通用知识的高置信推理，尚未在真机/编译环境验证。
- 【未证】：尚未验证，落地前需实测或进一步查证。

### 核心结论 TL;DR

1. iOS + Metal 官方路线 = 编译 **4+1 个核心 `.cpp`** + **`backends/imgui_impl_metal.mm` 一个渲染后端** + **自写约 20 行 UITouch 映射**；官方**不存在** iOS 输入后端（backends 目录只有 `osx`（macOS 专用）和 `metal`/`metal4` 渲染后端）。【已证】
2. 官方 iOS 示例挂在 `MTKView` 上；**悬浮 HUD 场景建议自建 `CAMetalLayer`**（或直接寄生在项目已有 Metal 渲染循环里），对比见 §1.3。【已证示例 / 推断建议】
3. 本版本（1.93）是"动态字体"体系：Metal 后端已支持，**无需再传 GlyphRanges、无需 Build()、也不要再用"2×字号加载 + FontGlobalScale=0.5"的 Retina 老配方**；`io.DisplayFramebufferScale` 会自动驱动字体现素密度。【已证】
4. 触摸输入走事件队列接口 `io.AddMousePosEvent / AddMouseButtonEvent / AddMouseSourceEvent(TouchScreen)`（官方示例即如此）；多指需"主触点"策略，**不能照抄**示例的 `anyObject` 写法（官方注释自嘲其多指行为 erratic）。【已证 / 推断】
5. **多视口（multi-viewport，多个 OS 窗口）在 master 分支不存在**：`ImGuiViewport` 注释明确 "always only one in 'master' branch"（imgui.h:223），相关 flag 全仓库仅文档提及一处（BACKENDS.md:186）；iOS 上完全不适用。【已证】

---

## 0. 克隆内容速览（与 iOS 相关的部分）

**顶层核心源码（要编的）**【已证】
```
imgui.cpp / imgui.h           核心：上下文、窗口、布局、输入状态机、公共 API
imgui_draw.cpp                绘制 + 字体光栅（内置 stb_truetype 后端, imgui_draw.cpp:17）
imgui_tables.cpp / imgui_widgets.cpp
imgui_demo.cpp                官方 Demo（可选，开发期建议带）
imconfig.h / imgui_internal.h 编译配置 / 内部 API
imstb_truetype.h / imstb_rectpack.h / imstb_textedit.h   被上述 cpp include，无需单独编译
```

**backends/（iOS 相关）**【已证】
```
imgui_impl_metal.h / .mm      ★ 本项目要用：Metal 渲染后端（ObjC 或 Metal-cpp C++）
imgui_impl_metal4.h / .mm     Metal 4 后端。"Metal 4 requires Apple Silicon and macOS 26+"（imgui_impl_metal4.h:3）→ iOS 16.6.1 不适用（推断）
imgui_impl_osx.h / .mm        macOS/Cocoa 平台后端（鼠标/键盘/剪贴板），非 iOS；作者自称 "Not well tested... prefer GLFW or SDL on Mac"
（没有任何 imgui_impl_ios.* —— iOS 触摸输入需自己写；见 §2）
```

**examples/（参考样例）**【已证】
```
examples/example_apple_metal/        ★ iOS/macOS 官方最小示例（iOS 触摸代码就在这里）
  main.mm                            全部逻辑：MTKView + ImGui_ImplMetal + UITouch→ImGuiIO
  iOS/Info-iOS.plist 等              iOS target 资源
  Makefile                           "# Makefile for example_apple_metal, for macOS only (**not iOS**)"（:1）
  *.xcodeproj                        双 target（iOS + macOS），iOS 用 Xcode 工程构建
examples/example_apple_metal4/       Metal4 版示例（不适用）
examples/example_glfw_metal|sdl2_metal|sdl3_metal*  桌面平台参考；README 建议"可移植需求优先 GLFW/SDL 版"
```

**其他有用目录**：`misc/fonts/binary_to_compressed_c.cpp`（字体内嵌工具，§3.1）；`docs/FONTS.md`（字体官方文档）；`docs/BACKENDS.md`（后端开发规范）。

---

## 1. iOS + Metal 集成步骤

### 1.1 需要编译哪些文件【已证】

| 类别 | 文件 | 说明 |
|---|---|---|
| 核心（必编） | `imgui.cpp`、`imgui_draw.cpp`、`imgui_tables.cpp`、`imgui_widgets.cpp` | 官方示例 Makefile 编的正是这 5 个 cpp（含 demo）；imgui_draw.cpp 内置 stb_truetype 字体光栅器，默认无需外部依赖 |
| 核心（可选） | `imgui_demo.cpp` | Demo 窗口；建议开发期保留、发布可去（推断） |
| 后端（必编） | `backends/imgui_impl_metal.mm`（+头文件） | 唯一需要的官方文件；**不要**把 backends 全目录塞进工程 |
| 输入（自写） | 自己的 `HUDView.mm` 等 | UITouch→ImGuiIO；可参考 `examples/example_apple_metal/main.mm:227-255` 的官方实现（§2） |

编译设置：`.mm` 按 ObjC++ 编译。官方 iOS 示例工程设置：`CLANG_CXX_LANGUAGE_STANDARD = gnu++14`、`CLANG_CXX_LIBRARY = libc++`、`CLANG_ENABLE_OBJC_ARC = YES`、`GCC_C_LANGUAGE_STANDARD = gnu11`（example_apple_metal.xcodeproj/project.pbxproj:302-306）。示例 Makefile（macOS 用）：`-std=c++11 -ObjC++ -fobjc-arc` + `-framework Metal -framework MetalKit -framework QuartzCore`（Makefile:9-10）。本项目按 C++14/17 设置均可（推断）。

**纯 C++ 偏好的选项**：backend 头文件提供 C++ 绑定分支——在 imconfig.h 里 `#define IMGUI_IMPL_METAL_CPP` 即用 Metal-cpp（`MTL::` 命名空间）编译该后端为 C++（imgui_impl_metal.h:51-73）。对云构建/TrollStore 路线，直接用默认 ObjC++ 更省事；上 Metal-cpp 属可选优化【推断】；iOS 上 metal-cpp 的实战可行性与引入成本【未证，需实测】。

### 1.2 初始化与每帧流程（官方示例骨架）【已证】

初始化（main.mm:47-69）：
```objc
id<MTLDevice> device = MTLCreateSystemDefaultDevice();
id<MTLCommandQueue> queue = [device newCommandQueue];

IMGUI_CHECKVERSION();
ImGui::CreateContext();                 // 1 个 UI 上下文
ImGuiIO& io = ImGui::GetIO(); (void)io;
ImGui::StyleColorsDark();
ImGui_ImplMetal_Init(device);           // 渲染后端挂到 device 上
// 字体：见 §3（示例默认没加载任何字体，用内嵌 ProggyForever/ProggyClean）
```

每帧（MTKView delegate `drawInMTKView`，main.mm:115-199，精简）：
```objc
io.DisplaySize = view.bounds.size;                                // 单位：点（points）
io.DisplayFramebufferScale = ImVec2(scale, scale);                // iPad = 2.0；来源 view.window.screen.scale ?: UIScreen.mainScreen.scale

id<MTLCommandBuffer> cb = [queue commandBuffer];
MTLRenderPassDescriptor* rp = view.currentRenderPassDescriptor;
if (rp == nil) { [cb commit]; return; }                           // 示例的防御写法

ImGui_ImplMetal_NewFrame(rp);          // 必须传当前帧 RenderPassDescriptor
ImGui::NewFrame();
... 构建 UI（Begin/Button/Text...）...
ImGui::Render();

rp.colorAttachments[0].clearColor = MTLClearColorMake(...);
id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);     // 必须在 encoder 存活期间调用
[enc endEncoding];
[cb presentDrawable:view.currentDrawable];
[cb commit];
```

后端 API 表面（imgui_impl_metal.h:31-43）：`ImGui_ImplMetal_Init(device)` / `Shutdown()` / `NewFrame(renderPassDescriptor)` / `RenderDrawData(drawData, commandBuffer, commandEncoder)`；设备资源（管线/采样器/字体纹理）由 Init→NewFrame 自动创建——**1.92 起已删除 `CreateFontsTexture()/DestroyFontsTexture()`**（imgui_impl_metal.mm:27）。

### 1.3 挂 MTKView 还是自建 CAMetalLayer？

| 维度 | MTKView（官方示例） | 自建 CAMetalLayer |
|---|---|---|
| 本质 | Apple 的 UIView 子类，**内部就是一层 CAMetalLayer**（推断） | 裸 `CAMetalLayer` 直接挂到任意 UIView.layer / overlay 窗口 |
| 便利性 | 自动管理 `currentRenderPassDescriptor`、`currentDrawable`、drawableSize 同步（`drawableSizeWillChange` 回调, main.mm:202-204）、可 delegate 驱动/手动绘制 | 全部手动：`drawableSize = bounds.size * contentsScale`、`nextDrawable`、自建 RenderPassDescriptor、present 时机自控 |
| 悬浮 HUD 适配 | 需要一块全屏/占位视图承载，压在原有 UI 上时层级/透明度要额外调（MTKView 默认不透明）【推断】 | ★ 灵活：层可加在 overlay 视图下、`isOpaque=false` + clearColor alpha=0 做透明覆盖、**按需重绘**（无交互时不渲染，省电）【推断】 |
| 驱动方式 | 内建 display link / setNeedsDisplay 模式 | 自己上 `CADisplayLink` 或事件触发重绘【推断】 |
| 官方态度 | README 自嘲"基于 Xcode 模板，可移植性差；优先学 glfw/sdl 版"（README.md:7） | 无官方示例 |

**建议（HUD 悬浮菜单 + 绘制层场景）**【推断】：
1. 若本项目 HUD 覆盖在**自家 App 界面**上：优先**自建 `CAMetalLayer` 挂 overlay 视图**（透明 + 按需重绘），或若宿主本身已有一个 Metal 渲染循环，**直接把 ImGui 画进宿主同一帧的 render pass**（最省一次 surface 开销）——这是集成度最高但改动最大的方案。
2. 若 HUD 是独立全屏页面/先跑通实验：直接抄官方 `MTKView` 示例，改动最少、最快出画面。
3. 若需求是"悬浮在**第三方 App**之上的系统级覆盖"：普通（含 TrollStore 未越狱）App 受沙箱限制做不到跨进程悬浮，需系统级手段——超出 ImGui 集成范畴【未证，建议先做路径验证再投入】。
4. sRGB/像素格式：官方示例未显式设置 `colorPixelFormat`（走 MTKView 默认）；自建 layer 时需**显式指定**（如 `bgra8Unorm` 或 `bgra8Unorm_sRGB`）并保持整条链路一致，否则颜色会发灰/过亮——sRGB 下 ImGui 颜色的观感差异【推断，真机对比一次即可确认】。

### 1.4 云构建（GitHub Actions macOS runner）接入注意【推断】

- Xcode/XcodeGen 工程把 `app/Sources/Render/imgui/` 下 **5 个 cpp + `backends/imgui_impl_metal.mm`** 加入 target sources；其余 backends/examples 不参与编译。
- `.mm` 由 Xcode 按扩展名自动用 ObjC++ 编译；**记得打开 ARC**（示例工程 ARC=YES，后端两代兼容）。
- 渲染层与触摸层建议放 `app/Sources/Render/`、`app/Sources/HUD/`（本项目已有目录结构）。
- 头文件搜索路径加 `imgui/` 与 `imgui/backends/`（Makefile:9 同款）。

---

## 2. 触摸输入映射（UITouch → ImGuiIO）

### 2.1 事件 API 要点【已证】

推荐用**事件队列接口**（queue 版），不要直接写 `io.MousePos` 等字段：

```cpp
io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);  // 标记来源；枚举注释："no hovering prior to initial press,
                                                        //  less precise initial press aiming, dual-axis wheeling possible"（imgui.h:2033）
io.AddMousePosEvent(x, y);                              // 队列一个指针位置
io.AddMouseButtonEvent(0, down);                        // 0 = 左键；触摸即"左键按下"
io.AddMouseWheelEvent(wheel_x, wheel_y);                // wheel_y>0 向上滚，<0 向下（imgui.h:2590）
io.AddFocusEvent(bool);                                 // 应用级焦点（imgui.h:2588-2592）
```
官方后端规范原文（BACKENDS.md:197-198）："Use `io.AddMousePosEvent()`, `io.AddMouseButtonEvent()`, `io.AddMouseWheelEvent()` to pass mouse events." / "Use `io.AddMouseSourceEvent()` if you are able to distinguish Mouse from TouchScreen from Pen inputs. **TouchScreen and Pen inputs requires different logic for some Dear ImGui features.**"

配套注意：
- `io.ConfigInputTrickleEventQueue = true`（默认）：同一帧里 "down + up" 这类事件会被摊到多帧处理，"improving interactions with low framerates"（imgui.h:2485）——触摸快速点按不会丢在帧缝里。【已证】
- 事件顺序：官方示例为 Source → Pos → Button（同一帧内先给位置再给按压）。【已证】

### 2.2 官方示例实现（直接可抄的起点）【已证，main.mm:227-255】

```objc
// 注意：官方自评"This touch mapping is super cheesy/hacky... we don't bother handling multitouch
// correctly at all. This causes the 'cursor' to behave very erratically when there are multiple
// active touches. But for demo purposes, single-touch interaction actually works surprisingly well."
-(void)updateIOWithTouchEvent:(UIEvent *)event
{
    UITouch *anyTouch = event.allTouches.anyObject;          // ← 多指时会"乱跳"，见下文改进
    CGPoint touchLocation = [anyTouch locationInView:self.view];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent(touchLocation.x, touchLocation.y);

    BOOL hasActiveTouch = NO;
    for (UITouch *touch in event.allTouches)                  // 任一指未结束 = 按住
    {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled)
        { hasActiveTouch = YES; break; }
    }
    io.AddMouseButtonEvent(0, hasActiveTouch);
}
-(void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
-(void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
-(void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event  { [self updateIOWithTouchEvent:event]; }
-(void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
```

逐点解读：
- **四个回调都要接**，尤其 `touchesCancelled`（来电/系统手势/切后台会触发；漏掉会造成"按钮永远按着"的卡死）。【已证示例覆盖 / 推断触发场景】
- 坐标系：`locationInView:self.view` 与 `io.DisplaySize = view.bounds.size` 同一坐标系（点），**不需要**乘屏幕倍数。【已证】
- `hasActiveTouch` 布尔聚合是对的（ImGui 核心是单指针模型，"按住"状态只需 0/1）。

### 2.3 多指改进方案（推荐落地写法）【推断，基于上述事实的设计，需真机验证】

```objc
// 主触点（primary touch）策略：第一根手指驱动物理指针，其余忽略（后续可扩展双指==滚轮）
@property (nonatomic, weak) UITouch *primaryTouch;

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.primaryTouch != nil) return;            // 已有主触点，忽略第 2+ 指
    UITouch *t = touches.anyObject;
    self.primaryTouch = t;
    [self sendPos:t]; ImGui::GetIO().AddMouseButtonEvent(0, true);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([touches containsObject:self.primaryTouch]) [self sendPos:self.primaryTouch];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event     { [self maybeRelease:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self maybeRelease:touches]; }
- (void)maybeRelease:(NSSet<UITouch *> *)touches {
    if (self.primaryTouch == nil) return;
    if ([touches containsObject:self.primaryTouch] || touches.count == 0) {
        self.primaryTouch = nil;
        ImGui::GetIO().AddMouseButtonEvent(0, false);
    }
}
- (void)sendPos:(UITouch *)t {
    CGPoint p = [t locationInView:self.view];
    ImGui::GetIO().AddMousePosEvent(p.x, p.y);      // 可在此夹取到 view.bounds 内
}
```
- 双指滚动 → 滚轮：在 `touchesMoved` 统计 2 指时，取纵轴位移增量 `io.AddMouseWheelEvent(0, -dy)`（正负按 imgui.h:2590 语义对齐）；或干脆用 ImGui 滚动条拖拽替代。【推断】
- 上屏键盘：`io.WantTextInput` 为 true 时可弹 `UIKeyInput`/自定义键盘（imgui.h:2611 原文："Mobile/console: when set, you may display an on-screen keyboard"）。如需文本输入建议自绘键盘或干脆禁用 InputText。【已证 API / 推断方案】

### 2.4 悬浮窗（HUD）场景注意事项

- **命中模型**：ImGui 窗口是矩形命中，没有逐像素穿透；"穿透"只能做在 UIKit 层——overlay 视图的 `hitTest`/`point(inside:)` 只让 HUD 面板矩形返回命中，其余区域返回 nil 透给底层。【推断】
- **分发判据**：`io.WantCaptureMouse`（`SetNextFrameWantCaptureMouse` 可强制）是"事件给 ImGui 还是给底层"的官方判据（imgui.h:476 注释明确引 FAQ；1134 有 override 函数）。HUD 与游戏/主界面共存时用它做路由。【已证】
- **纯展示 HUD**（不接收输入的面板）：加 `ImGuiWindowFlags_NoInputs`（= `NoMouseInputs | NoNavInputs | NoNavFocus`，imgui.h:1204）。【已证】
- **触摸目标偏小**：`style.TouchExtraPadding` 可扩大控件命中盒，官方警告"don't grow this too much"（imgui.h:2355，因控件重叠时优先级只按先后）。更稳的做法是整体加大 `FramePadding/ItemSpacing` 或 `style.ScaleAllSizes(1.2~1.5)`。【已证字段 / 推断做法】
- **触屏无 hover**：按下即点击（`ImGuiMouseSource_TouchScreen` 注释即此语义，imgui.h:2033）；按钮反馈主要靠 active 态颜色，配色上要保证按下态明显（iOS 风格）【推断】。
- **焦点丢失**：进后台/切 App 时调用 `io.AddFocusEvent(false)`，核心会执行 `ClearInputKeys()/ClearInputMouse()`，避免残留按压态（imgui.h:2557-2560 提到该机制）。【已证机制 / 推断接线时机】

---

## 3. 中文字体方案

### 3.1 三种字体供给方式对比

| 方式 | 做法 | 优点 | 缺点/注意 |
|---|---|---|---|
| **打包进 .app bundle**（推荐） | `[[NSBundle mainBundle] pathForResource:ofType:]` 取路径 → `AddFontFromFileTTF` | 离线可用、路径稳定只读、TrollStore 场景无体积硬限制 | IPA 体积增大（子集化可控）；改字体要重发版 |
| 运行时加载 | 下载/拷入 `Documents/` → `AddFontFromFileTTF` | IPA 小、可热换字体 | 依赖网络/首次体验、要校验完整性；沙箱内路径需自管【推断】 |
| **编译进二进制** | `misc/fonts/binary_to_compressed_c.cpp`（stb_compress 压缩成 C 数组，U8/U32/Base85 三种编码）→ `AddFontFromMemoryCompressedTTF()` | 单文件分发、无文件系统依赖 | 源码体积膨胀；官方注明 Base85 编码"will be obsoleted"（binary_to_compressed_c.cpp:1-24；imgui.h:3830-3831）【已证】 |

建议：**打包"子集化 TTF"进 bundle** 为主；若将来做多语言热更新再考虑运行时加载。【推断】

### 3.2 候选开源中文字体（可内嵌）

| 字体 | 许可 | 备注 |
|---|---|---|
| **Noto Sans SC / Noto Sans CJK SC** | SIL OFL 1.1（推断） | ★ 首推：ImGui 官方 FONTS.md 示例用的就是 Noto Sans CJK（日文版）——`io.Fonts->AddFontFromFileTTF("NotoSansCJKjp-Medium.otf");`（FONTS.md:226）【已证引用】 |
| **思源黑体 Source Han Sans SC** | SIL OFL 1.1（推断） | 与 Noto CJK 同一设计，选一即可 |
| **霞鹜文楷 LXGW WenKai** | SIL OFL 1.1（推断） | 直发 TTF，文楷风格，HUD 标题可用 |
| **更纱黑体 Sarasa Gothic** | OFL（推断） | 基于 Iosevka+思源，工程感强 |
| 阿里巴巴普惠体 / MiSans / HarmonyOS Sans | "免费商用"类 | 条款各不同、可能要求随版本更新核对【未证，选用前查最新许可原文】 |

子集化流程（推荐！）【推断，体积数字需实测】：
```bash
# fonttools 的 pyftsubset；chars.txt 放常用字+ASCII+中文标点
pyftsubset SourceHanSansSC-Regular.otf \
  --text-file=chars.txt \
  --output-file=SourceHanSansSC-subset.ttf \
  --layout-features='' --no-hinting --desubroutinize
```
- 常用字≈3500 + ASCII + 标点，产出约 1~3 MB 级（完整 CJK OTF 十几 MB）。
- OTF/CFF 支持：内置 stb_truetype **支持 OTTO/CFF**（imstb_truetype.h:1303-1305 识别 "OTTO"，:1412-1418 CFF 初始化）【已证】；但为规避工具链差异，子集化输出建议转 `.ttf`（glyf）【推断】。
- 若懒得子集化：也可用 `ImFontGlyphRangesBuilder` 运行时收集实际用到的字（imgui.h:3758-3772），代价是首帧更多光栅化【已证 API / 推断性能】。

### 3.3 ImGui 加载代码要点（**1.93 动态字体版，别抄旧教程！**）

**本仓库正确写法**（1.92+ 动态字体 + Metal 后端已支持纹理动态更新）：
```cpp
ImGuiIO& io = ImGui::GetIO();
io.Fonts->AddFontFromFileTTF("/path/to/NotoSansSC-subset.ttf");       // 不传 GlyphRanges！
// 想指定基础字号：
// io.Fonts->AddFontFromFileTTF(path, 17.0f);                        // 大小随意，后续 PushFont 可换尺寸
```

依据：【已证】
- FONTS.md:208："🆕 **Since 1.92, with an up to date backend: specifying glyph ranges is unnecessary. All the GetGlyphRangesXXX() functions are marked obsolete.**"
- Metal 后端在 `Init()` 里设置 `io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures`（imgui_impl_metal.mm:435-436），即"up to date backend"：字形**按需加载**、纹理自动创建/扩容（imgui.h:3892 "Texture may be created/resized at any time..."），不需要 `Build()/GetTexDataAsRGBA32()`（imgui.h:3851-3859）。
- `ImFontConfig::GlyphRanges` 已标注 `*LEGACY*`（imgui.h:3716）；`AddFontFromFileTTF(filename, size, cfg, glyph_ranges)` 的旧参数仍在（imgui.h:3828），但新系统下无用。
- 字体尺寸已动态化：`PushFont(font, size)`、`GetFontBaked()`（imgui.h:518-536）；`GetFontSize()` 是已乘全局系数的值，别再塞回 `PushFont`。【已证】

**兼容旧写法的备份（万一某天后端/宏配置回退）**：
```cpp
#ifndef IMGUI_DISABLE_OBSOLETE_FUNCTIONS
io.Fonts->AddFontFromFileTTF(path, 17.0f, nullptr,
    io.Fonts->GetGlyphRangesChineseSimplifiedCommon());   // "Default + 2500 常用简体字"（imgui.h:3877）
// ChineseFull = 21000 字（imgui.h:3876），数组必须常驻（imgui.h:3716, 3814）
#endif
```
- 旧后端（不支持 RendererHasTextures）才需要 ranges + `ImFontConfig::RasterizerDensity`（标 LEGACY，imgui.h:3727；imgui.cpp:561）。

其他要点：
- 图标字体合并：`ImFontConfig::MergeMode = true`（imgui.h:3710），并可配 `GlyphExcludeRanges` 去重（imgui.h:3717）。
- 更高质量：imconfig.h `#define IMGUI_ENABLE_FREETYPE` 启用 FreeType 光栅（示例 main.mm:77 注释推荐；实现位于 `misc/freetype/`）——iOS 需把 `misc/freetype/imgui_freetype.cpp` 加入编译并链接 freetype，或内嵌 freetype 源码【已证注释 / 推断集成成本】。对内置 stb_truetype 效果不满意再上【推断】。

### 3.4 性能/内存注意【推断，除注明外】

- 动态字体是增量光栅：**首次出现大量陌生汉字时会边渲边录**，HUD 首开可能有轻微卡顿——可在启动后渲染两帧带全字表的隐藏文本"预热"（或接受动态开销）。
- 纹理上限：Metal 纹理上限 16384×16384（设备级别），常规规模远够，无实际操作风险。
- 缓存压缩：`ImFontAtlas::CompactCache()` 可压缩字形缓存与纹理（imgui.h:3833）【已证】。

---

## 4. Retina / 分辨率 / 缩放

### 4.1 两个坐标系统【已证】

| 概念 | 值/来源 | 依据 |
|---|---|---|
| ImGui 逻辑坐标 | **点（points）**，全部 UI/命中/触摸坐标统一用它 | 示例 main.mm:118-119（`io.DisplaySize = view.bounds.size`） |
| `io.DisplaySize` | 视图 bounds 尺寸（点）；注释："Main display size, in pixels... May change every frame" | imgui.h:2461 |
| `io.DisplayFramebufferScale` | iPad = 2.0；注释："Main display density. For retina display where window coordinates are different from framebuffer coordinates. **This will affect font density** + will end up in ImDrawData::FramebufferScale." | imgui.h:2462；示例取 `view.window.screen.scale ?: UIScreen.mainScreen.scale`（main.mm:124-126） |
| 渲染侧换算 | `fb = DisplaySize × FramebufferScale`；裁剪矩形 `clip_scale = FramebufferScale`（"often (2,2)"） | imgui_impl_metal.mm:170-171, 208-211, 242-244 |

### 4.2 **1.92+ 重大变化：不要再做"老 Retina 配方"**【已证】

imgui.cpp:559-562（官方升级说明）原文要点：
> "if your app was solving the OSX/iOS Retina screen specific logical vs display scale problem by setting `io.DisplayFramebufferScale` (e.g. to 2.0f) + setting `io.FontGlobalScale` (e.g. to 1.0f/2.0f) + loading fonts at scaled sizes (e.g. size X * 2.0f): **This WILL NOT map correctly to the new system!** Because font will rasterize as requested size.
> - With a legacy backend (< 1.92): ... set `ImFontCfg::RasterizerDensity = N`.
> - **With a new backend (1.92+): This should be all automatic. FramebufferScale is automatically used to set current font RasterizerDensity.**"

对号入座：本项目 = 新后端（Metal 已支持 RendererHasTextures）→ 结论：
- ✅ 照常设置 `io.DisplayFramebufferScale = 2`；字体**按点值正常加载**（如 17.0f），Retina 锐度自动处理。
- ❌ 不要"2× 字号加载 + FontGlobalScale=0.5"（老教程写法，1.93 下会错）。
- ❌ 不需要手动 `RasterizerDensity`（那是旧后端才需要）。
- 且 `io.FontGlobalScale` 已废弃 → 用 `style.FontScaleMain`（imgui.h:2679 注明"Moved io.FontGlobalScale to style.FontScaleMain in 1.92.0"）。
- 机制佐证：`g.CurrentPixelDensity = viewport->FramebufferScale.x ?: io.DisplayFramebufferScale.x`（imgui.cpp:4787-4788）。
- FONTS.md:115 同样声明："Since 1.92, with an updated backend, macOS style pixel/backing style scale is automatically handled."

**想整体放大 UI（例如 HUD 想更大）**（FONTS.md:113-114）【已证】：
```cpp
style.FontScaleDpi = 2.0f;   // 放大所有字体（= your_content_scale）
style.ScaleAllSizes(2.0f);   // 放大尺寸/间距/圆角等（初始化时调用，或每帧循环开头）
```
注意：这是"更大"，与"更清晰"是两回事（清晰度是老配方解决的问题，现在已自动）。

### 4.3 其他缩放注意

- 自建 CAMetalLayer 时：`drawableSize = bounds.size * contentsScale` 必须手动同步（MTKView 会自动，见 main.mm:202 的 `drawableSizeWillChange` 回调）。【已证示例 / 推断自建】
- 用 `UIScreen.scale`（=2.0）即可；`nativeScale` 是渲染降采样场景的值，别与 drawableSize 混算。【推断】
- 横竖屏切换/分屏：DisplaySize 每帧都可变（imgui.h:2461 "May change every frame"），监听 bounds 变化重设即可。【已证注释】
- ImGui 样式本身按点设计：本项目是 iPad 大屏，一般无需全局缩放；若控件对触摸而言偏小，优先按 §2.4 的方式调大而不是动 FramebufferScale。【推断】

---

## 5. 已知坑清单

### 5.1 Metal 后端

1. **调用顺序**：每帧必须 `设置 DisplaySize/FramebufferScale → ImGui_ImplMetal_NewFrame(descriptor) → ImGui::NewFrame()`；`RenderDrawData` 必须夹在 render encoder 的 begin/end 之间（签名强制传 encoder）。【已证示例序列 + API 签名（imgui_impl_metal.h:33-36）】
2. **管线缓存键**：后端按 你传入的 RenderPassDescriptor 的 `sampleCount` + 各颜色附件 `pixelFormat` 建/取管线（imgui_impl_metal.mm:66-72, 489-493）。**别在同一层上频繁换像素格式/开关 MSAA**，会产生多条管线（有缓存，但重建有成本）。【已证机制 / 推断建议】
3. 多颜色附件现在支持（渲染到第一个、其余不动；2026-10-06 变更，imgui_impl_metal.mm:19）。【已证】
4. ARC / 非 ARC 都支持（2022-06-30 changelog；示例工程 ARC=YES）。metal-cpp 路径的泄漏已修（2025-01-08）。【已证】
5. **支持多 ImGui context**：后端数据是 per-context 的（2022-04-27 changelog；多 context 泄漏 2025-01-08 修复）。【已证】
6. 动态字体纹理：后端会在渲染时遍历 `platform_io->Textures[]` 创建/更新/销毁纹理（imgui.h:3806-3809）；若自己实现纹理管理，注意 `ImTextureID_Invalid` 自 2026-03-12 起缺省非 0（2026-03-19 changelog），**不要用 0 判空**。【已证】
7. 线程：ImGui 与后端都按单线程主循环使用（事件收集与 NewFrame/Render 同线程）；本项目 = UIKit 主线程。【推断（通用规则）】
8. **Metal 4 后端不适用**：`imgui_impl_metal4.*` 是新东西，但 "Metal 4 requires Apple Silicon and macOS 26+"（imgui_impl_metal4.h:3）→ iOS 16.6.1 用经典 `imgui_impl_metal`。【已证（macOS 表述）+ 推断（iOS 同理）】

### 5.2 窗口层级冲突 / 悬浮【全部为推断，需真机验证】

- overlay `UIWindow`：`windowLevel` 调高（如 `.alert` 级）、`backgroundColor = .clear`、`isOpaque = false`，rootVC 的 view 上挂 CAMetalLayer；非面板区域 `hitTest` 返回 nil 实现点击透传。
- **系统手势区**：iPad 底部 home indicator、边缘手势会延迟或吞掉触摸；`preferredScreenEdgesDeferringSystemGestures` 可减少延迟；HUD 交互元素避开最底边 ~20-30pt。
- **触摸取消**：切后台/来电/系统手势触发 `touchesCancelled`——必须释放按压态（官方示例已覆盖该回调）；另建议进后台时 `io.AddFocusEvent(false)`。
- 键盘/系统弹窗层级永远更高；不要在 HUD 上依赖"最顶层"假设。
- 跨 App 悬浮（TrollStore 未越狱）：普通 App 无跨进程悬浮能力【未证——但这是立项级前置问题，建议先单独验证再投入 HUD 研发】。

### 5.3 "多窗口"的三种含义

1. **ImGui 多视口（multi-viewport / 多 OS 窗口）**：master 分支**不存在**——`ImGuiViewport` 注释 "A Platform Window (**always only one in 'master' branch**)"（imgui.h:223）；`ImGuiBackendFlags_` 枚举里没有 PlatformHasViewports（imgui.h:1765-1773）；全仓库仅 BACKENDS.md:164-172,186 说明"多视口是 'docking' 分支功能"。iOS 上更无意义。**结论：HUD 只能画在单一 view/layer 里。【已证】**
2. **iPad 多窗口（UIScene / 分屏多实例）**：每个场景 = 独立 VC，需要各自独立的 ImGui context + 各自 `ImGui_ImplMetal_Init`；后端支持多 context（见 5.1-5），共享同一 `MTLDevice` 可行；**不要**让两个场景共用同一 context 跑 `NewFrame`。【已证后端能力 + 推断用法】本项目若单场景运行可忽略。
3. **应用内多个 ImGui 窗口（面板）**：完全没问题，就是常规 `Begin/End` 多开；注意把 `io.IniFilename` 处理对——
   - 默认 `"imgui.ini"` 是**相对当前工作目录**的（imgui.h:1142-1144, 2465），iOS 沙箱下不可靠；
   - 方案 A：`io.IniFilename = NULL;` 关闭自动读写，自己 `LoadIniSettingsFromMemory/SaveIniSettingsToMemory`；
   - 方案 B：指到 `Documents/` 下的绝对路径。
   【已证注释 / 推断 iOS 行为】另：HUD 类窗口建议统一加 `ImGuiWindowFlags_NoSavedSettings`（imgui.h:1191），不把状态写 ini。【已证 flag】

---

## 6. 对白米饭复刻的落地建议

1. **目录与编译**：imgui 已就位于 `app/Sources/Render/imgui/`；云构建工程只需加入 5 个核心 cpp + `backends/imgui_impl_metal.mm`（§1.1、§1.4）。
2. **绘制层**：先用 `MTKView` 路线抄官方示例跑通"能画汉字+能点按钮"的最小版本；随后按 HUD 需求切换到 **透明 `CAMetalLayer` overlay + 按需重绘**（§1.3；如需与宿主共帧，直接并入宿主 render pass）。
3. **字体**：选 OFL 系（Noto Sans SC / 思源黑体）子集化为 `.ttf` 打包；1.93 下 `AddFontFromFileTTF(path)` 即可，**不传 GlyphRanges、不 Build**（§3.3）。HUD 首次弹清前做字体预热（§3.4）。
4. **触摸**：从官方 `updateIOWithTouchEvent` 起步，换成 §2.3 的"主触点 + 双指滚轮"版本；接全四个回调 + 后台 `AddFocusEvent(false)`；HUD 面板 `NoSavedSettings/NoCollapse`，纯展示区 `NoInputs`（§2.2-2.4）。
5. **真机验证清单**（iOS 16.6.1 / iPad）【建议优先跑】：
   [ ] Retina 文字锐度（确认"自动密度"生效，无需老配方）
   [ ] 动态字体纹理自动创建（工程里不应存在 `CreateFontsTexture` 调用）
   [ ] 触摸精度 / 快速点按不丢（trickle 行为）
   [ ] 切后台→返回后无卡死按钮（focus/cancel 处理）
   [ ] 透明 overlay 的 sRGB 颜色观感
   [ ] 帧率与发热（按需重绘是否生效）

---

## 附录 A：关键源码索引（当前 commit）

| 主题 | 位置 |
|---|---|
| 版本号 | imgui.h:32-33 |
| ImGuiIO 核心字段 | imgui.h:2459-2465（DisplaySize/DisplayFramebufferScale/IniFilename） |
| 输入事件 API | imgui.h:2588-2594（AddMousePos/Button/Wheel/Source/Focus） |
| 鼠标来源枚举（TouchScreen） | imgui.h:2030-2035 |
| 触摸命中扩展 | imgui.h:2355（TouchExtraPadding） |
| 事件摊平 | imgui.h:2485（ConfigInputTrickleEventQueue） |
| HUD 相关窗口 flags | imgui.h:1188-1204（NoCollapse/AlwaysAutoResize/NoBackground/NoSavedSettings/NoMouseInputs/NoDecoration/NoInputs） |
| WantCaptureMouse 判据 | imgui.h:476, 1134 |
| 字体配置 | imgui.h:3700-3740（ImFontConfig；GlyphRanges *LEGACY* 3716；RasterizerDensity LEGACY 3727） |
| 字体加载 API | imgui.h:3828-3831（AddFontFromFileTTF / Memory / Compressed / Base85） |
| Glyph ranges | imgui.h:3866-3881（ChineseSimplifiedCommon=2500 字, ChineseFull=21000 字） |
| 字体缩放字段 | imgui.h:2330-2334（FontSizeBase/FontScaleMain/FontScaleDpi）；518-536（PushFont/GetFontSize） |
| Retina 老配方作废说明 | imgui.cpp:559-562 |
| 字体密度自动机制 | imgui.cpp:4787-4788；imgui_draw.cpp:4394-4398 |
| 内置光栅器 | imgui_draw.cpp:17, 89-162（stb_truetype include） |
| OTF/CFF 支持 | imstb_truetype.h:1303-1305, 1412-1418 |
| 多视口不存在 | imgui.h:223；imgui.h:1765-1773；BACKENDS.md:164-172 |
| Metal 后端 flags/Init | imgui_impl_metal.mm:432-439 |
| Metal 后端帧换算/管线键 | imgui_impl_metal.mm:62-72, 170-171, 208-244, 489-493 |
| 后端 changelog（关键行） | imgui_impl_metal.mm:19-45 |
| Metal4 限制 | imgui_impl_metal4.h:3 |
| iOS 示例：初始化 | examples/example_apple_metal/main.mm:47-69 |
| iOS 示例：每帧循环 | examples/example_apple_metal/main.mm:115-199 |
| iOS 示例：触摸映射 | examples/example_apple_metal/main.mm:227-255 |
| 官方字体文档 | docs/FONTS.md:111-115（DPI）、208-233（ranges 作废+示例） |
| 官方后端规范 | docs/BACKENDS.md:186-199（平台后端职责、事件接口、像素密度） |
| 字体内嵌工具 | misc/fonts/binary_to_compressed_c.cpp:1-24 |
| 工程编译设置 | examples/example_apple_metal/example_apple_metal.xcodeproj/project.pbxproj:302-337；Makefile:1-10 |

## 附录 B：证据等级速查

- 【已证】主要结论均已附 `文件:行号`，可逐条复核。
- 【推断】集中在：MTKView/CAMetalLayer 取舍与 overlay 建议、云构建接入、多指改进稿、UIKit 层级/hitTest 行为、字体许可描述、子集体积数字。
- 【未证】：字体许可证细节（如阿里普惠体等免费商用条款）、iOS 版 metal-cpp 可行性、跨 App 悬浮路径、"MTKView 内部就是 CAMetalLayer"的官方表述（Apple 文档未在本次克隆范围内核对）。
