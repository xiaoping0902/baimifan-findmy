# 审查报告 · HUD 链路：进程起来了但窗口不显示

- 日期：审查当日
- 对象：`C:\Users\xiaoping\Desktop\白米饭复刻`
- 目标机：iPad Pro M2 (iPad14,4) / iPadOS 16.1 / TrollStore
- 审查方式：**纯静态 + 二进制级证据**（未改任何源码）
- 已复核的外部事实：`dist/FindMy-M4.3.ipa`（2026-10-15 04:15 构建，exe 1,231,744 B）与 `dist/FindMy-unsigned.ipa`、`dist/m43.zip` 内 **同一份二进制**

---

## 0. 证据等级定义

| 标记 | 含义 |
|---|---|
| 【已证·源码】 | 本工程源码里逐行可核对的 |
| 【已证·二进制】 | 我把已打包 IPA 里的 `FindMy` Mach-O 解出来，解析了 section / 符号表 / 方法表 / 字符串得到的（不是猜的） |
| 【已证·原版】 | 从 `C:\Users\xiaoping\Desktop\codex 项目\analysis\baimifan-20261013\Payload\IdOsVEN.app\MobileStore`（原版 16.9 MB，已解密 `cryptid=0`）里直接读出的 |
| 【推断】 | 有代码依据，但缺少设备态证据，需要真机验证 |
| 【未证】 | 无法从此机器确认 |

> ⚠️ 先纠一个我自己的坑，说明后面为什么要看二进制：我第一次在 `__TEXT,__cstring` 里搜 `[MF][HUD]` 是**搜不到的**，因为 Clang 对含中文的 `@"..."` 字面量走的是 **`__TEXT,__ustring`（UTF-16LE）**。复查后确认：**所有 HUD 日志字符串都在二进制里，一条都没被裁掉**【已证·二进制】。这条结论直接决定了「syslog 里没有 [MF] 输出」该怎么解读——见 §3。

---

## 1. 结论速览（按可能性排序）

| # | 结论 | 概率 | 核心依据 |
|---|---|---|---|
| **1** | **窗口「建了、但没进合成器」**：HUD 子进程不是一个被 FrontBoard 承认前台的应用 → 拿不到 `UIWindowScene`/窗口服务器 context → 两个 `UIWindow` 从没被合成过。`SBSAccessibilityWindowHostingController` 拿到的 `contextId` 是 0，SpringBoard 自然什么都不显示 | **~70%** | §2.2 + §1.3；`Info.plist` 无 `UIApplicationSceneManifest`（【已证·二进制】）；HUD 进程用默认 `UIApplication`（`main.mm:29` 传 `nil`） |
| **2** | **HUD 子进程在走到建窗之前就卡死/没跑到**：`didFinishLaunching:` 从未被调用（日志覆盖了它前后每一步，但一条都没出来 → 说明连第 72 行都没到） | **~50%**（与 #1 是同一根因的两面） | `MFHUDAppDelegate.mm:72/126/130/138` 的 NSLog 分布；启动早期日志 `main.mm:28` 也不见 |
| **3** | **原版靠自定义 `HUDMainApplication`（`NSPrincipalClass`）+ 一整套 hosting 机制解决这件事，复刻把这层整个丢掉了** | **~55%** | 【已证·原版】原版二进制含 `HUDMainApplication` / `MainApplication` / `HUDMainApplicationDelegate` / `_accessibilityInit` / `_installEventRunLoopSources:` / `_enqueueHIDEvent:` / `_isWindowServerHostingManaged` / `_drawingHostingController` / `_MenuHostingController` / `_drawingContext`；复刻二进制里这些**一个都没有** |
| **4** | **`_contextId` 取法可能根本不对**：原版 `_contextId` 是**自己的 ivar**（`HUDMainApplication._contextId`），复刻却去问 `UIWindow` 要 `_contextId`（`MFHUDAppDelegate.mm:49-54`） | **~35%** | 【已证·原版】`_contextId` 出现在原版属性/ivar 名表里，与 `_drawingContext`/`_menuContext` 同处一族；【已证·二进制】复刻的 `__objc_ivar` 表里没有任何 `_contextId` 字段 |
| **5** | **子进程被 RunningBoard 立刻挂起（suspended）**：非前台、无 background mode、无 task assertion | **~30%** | `MFHUDLauncher.mm:57` `posix_spawn` 未带任何 attr、未申请 assertion；【推断】 |
| **6** | **窗口被画出来了但看不见**：`MFDrawingLayer` 每帧把整个屏幕清成 `alpha=0`，且 ImGui 菜单窗层级比绘制窗**低 40** | **~10%**（只解释「菜单看不见」，不解释「连日志都没有」） | `MFOverlayView.mm:112`；`MFHUDAppDelegate.mm:78` vs `:103` |
| **7** | **渲染链自己就断了**（Metal device 为 nil / 管线创建失败） | **~10%** | `MFOverlayView.mm:38-39` 未判空；`imgui_impl_metal.mm:644-649` |

**一句话**：这不是「窗口属性写错了」的问题，是**「谁有资格往屏幕上合成」的架构问题**。原版为这件事专门写了 `HUDMainApplication` 和一套 hosting controller；复刻版把窗口建出来就直接交给 SBS，中间那一步缺失。

---

## 2. 逐条问题清单（含文件:行号）

### 一、为什么窗口不显示

#### ◼ 1.1 两个 `UIWindow` 是否创建并 `makeKeyAndVisible`？

**代码层面：是的，写法没毛病。**

- 绘制窗：`MFHUDAppDelegate.mm:76` 建窗 → `:77-81` 属性 → `:83-86` 根 VC → `:96` `hidden=NO` → `:97` `makeKeyAndVisible` → `:98` 存强引用
- 菜单窗：`MFHUDAppDelegate.mm:102-121` 同构

【已证·二进制】两个窗口类都存在且方法体在：
```
-[MFHUDWindow _isSystemWindow]                0x10000a244
-[MFHUDWindow _isSecure]                      0x10000a24c
-[MFHUDWindow _shouldCreateContextAsSecure]   0x10000a254
-[MFHUDWindow _ignoresHitTest]                0x10000a25c
-[MFHUDWindow hitTest:withEvent:]             0x10000a260
-[MFHUDAppDelegate application:didFinishLaunchingWithOptions:]  0x10000a334
__ZL12MFHostWindowP8UIWindow                   0x10000a9ec
+[MFHUDAppDelegate isHUDProcess]              0x10000a328
```
`makeKeyAndVisible` / `_contextId` / `SBSAccessibilityWindowHostingController` / `registerWindowWithContextID:atLevel:` 这些字符串在二进制里各出现 1–2 次【已证·二进制】。

**但有个硬前置**：整个建窗流程全在 `application:didFinishLaunchingWithOptions:` 里面（`MFHUDAppDelegate.mm:69-145`）。**这个方法不被调用 = 窗口根本不存在。**

- 【已证·源码】`MFHUDAppDelegate.mm` 里的 4 条日志分别打在：进入方法后（`72`）、绘制窗渲染失败（`126`）、菜单窗渲染失败（`130`）、托管结果（`138`）。
- 你实测「syslog 里没有任何 `[MF]` 输出」——**连第 72 行那条都没有**。
- 而 `main.mm:28` 的 `NSLog(@"[MF] 以 HUD 角色启动")` 在 `UIApplicationMain` **之前**，比它更早。它也没出来。

**结论**：要么子进程不是从这个 `main()` 走的，要么它在 `UIApplicationMain` 内部就卡死了/被杀了。**这是全案最需要优先钉死的一点。**【推断，需真机验证，见 §4.1】

---

#### ◼ 1.2 窗口层级 + iPadOS 16 的 Scene 改动

**窗口层级本身没问题。**
- 绘制窗 `UIWindowLevelStatusBar + 20`（`MFHUDAppDelegate.mm:78`）
- 菜单窗 `UIWindowLevelStatusBar - 20`（`MFHUDAppDelegate.mm:103`）
- 【已证·二进制】`_UIWindowLevelStatusBar` 在导入符号表里，两个窗口都是 `CGFloat` double 传参，格式串 `"%.0f"` 对得上（`MFHUDAppDelegate.mm:58`）
- 与原版对齐结论一致：`DrawingWindow` 在状态栏之上 20，`HUDImguiWindow` 在状态栏之下 20【已证·原版】（`docs/复刻总方案.md:41`、`evidence/followup-ui-windows.md:11-12`）

**Scene 才是重点。**

- 【已证·二进制】`app/Support/Info.plist` **没有** `UIApplicationSceneManifest`。我把已打包 IPA 的 `Info.plist` 解出来逐键核对过，键列表里确实没有它，也没有 `UISceneConfigurations` / `UISceneDelegate`。
- 【已证·二进制】二进制里同样搜不到 `UIApplicationSceneManifest` / `UISceneConfigurations` / `UISceneSessionRole` 字符串。

**这对「窗口显不显示」意味着什么：**

1. 走 legacy（非 Scene）路径这件事，**本身不必然是问题**——原版也没有 Scene manifest【已证·原版：原版 `Info.plist` 里没有该键】，原版在设备上能显示。
2. **但在 iOS 13+，一个 `UIWindow` 之所以能被合成，前提是它挂上了 `UIWindowScene`（或 legacy 的主 Screen）。** 一个 `posix_spawn` 起来、SpringBoard/FrontBoard 完全不知情的进程，是拿不到 scene 的：没有 scene → 没有 `CAContext` → 窗口没有窗口服务器端口可画。
3. **所以「原版没有 Scene manifest 也能显示」恰恰反证了：原版不是靠 Scene 解决的，而是靠 `NSPrincipalClass = HUDMainApplication` 那一层自己把窗口服务器那套接起来的。**【推断，证据强度高】

> ⚠️ 这里要明确说清：`Info.plist` 是否加 `UIApplicationSceneManifest` **不是本 case 的关键**。加了它，一个永不成前台的自派生进程还是拿不到 scene。它只能排除「legacy 路径被系统弃用」这一个小嫌疑。

**新发现（重要，原版证据）**

| 项 | 原版（【已证·原版】） | 复刻（【已证·二进制】） |
|---|---|---|
| `NSPrincipalClass` | **`HUDMainApplication`** | 无（`main.mm:29` 给 `UIApplicationMain` 传 `nil` → 用系统默认 `UIApplication`） |
| UIApplication 子类 | `HUDMainApplication`、`MainApplication` 两个 | **一个都没有** |
| HUD 代理类 | `HUDMainApplicationDelegate` | `MFHUDAppDelegate`（普通 `UIResponder`） |
| 窗口托管 | `_drawingHostingController`、`_MenuHostingController`、`_drawingContext`（属性类型 `T^v` = 裸指针）三个成员 | 无（每次 `MFHostWindow()` 现 new 一个 controller，用完就丢） |
| 事件接管 | `_installEventRunLoopSources:`、`_enqueueHIDEvent:`、`_accessibilityInit` | **无** |
| 托管状态位 | `_isWindowServerHostingManaged` | 无 |

【已证·原版】这些符号原文（取自 `MobileStore` 的 `__objc_methname` 区）：
```
HUDMainApplication / MainApplication / HUDMainApplicationDelegate
HUDImguiWindow / DrawingWindow / ImGuiDrawView / HUDBackdropView / HUDBackdropLabel
_contextId / _drawingContext / _drawingHostingController / _MenuHostingController
_isWindowServerHostingManaged / _isRemoteHUDActive / RemoteHUD
_accessibilityInit / _installEventRunLoopSources: / _enqueueHIDEvent: / _addTouch:forDelayedDelivery:
SBSAccessibilityWindowHostingController / registerWindowWithContextID:atLevel: / ToggleDrawingWindow
```
原版的 `Info.plist` 还带 `UIApplicationSystemWindowsSecureKey = True`、`UIApplicationShowsViewsWhileLocked = False`、`UILaunchStoryboardName = LaunchScreen`、`CFBundleURLTypes`（scheme `MobileStore`，用于进程间/场景唤起）。

**修法方向**（不是让你改代码，是给方向）：把窗口服务器那一层补回来 —— 至少要有自己的 `UIApplication` 子类接管 `_accessibilityInit` 那类的初始化，并把 hosting controller 与 `drawingContext` 长期持有（而不是每次现建现丢）。

---

#### ◼ 1.3 `SBSAccessibilityWindowHostingController` 的调用

【已证·源码】`MFHUDAppDelegate.mm:34-60`：

```objc
35:  Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
40:  id controller = ((id (*)(id, SEL))objc_msgSend)([cls alloc], sel_registerName("init"));
43:  SEL regSel = sel_registerName("registerWindowWithContextID:atLevel:");
49:  SEL ctxSel = sel_registerName("_contextId");
50:  if (![window respondsToSelector:ctxSel]) { NSLog(...没有 _contextId); return NO; }
54:  uint32_t ctxId = ((uint32_t (*)(id, SEL))objc_msgSend)(window, ctxSel);
55-56: objc_msgSend(controller, regSel, ctxId, (double)window.windowLevel);
58:  NSLog(@"已托管窗口 contextId=0x%x level=%.0f", ...);
59:  return YES;
```

**问题 A（确定）：返回值没判、失败也报成功**
`registerWindowWithContextID:atLevel:` 的返回值（BOOL）被丢弃，第 58–59 行无论发生什么都会打「已托管窗口」并 `return YES`。所以 `MFHUDAppDelegate.mm:136-141` 的「托管结果：菜单窗=1 绘制窗=1」**即使 SpringBoard 完全没理你也会显示成成功**。这解释了为什么你会觉得「托管成功了」。

**问题 B（高度可疑）：`_contextId` 打在了错误的对象上**
- 【已证·原版】原版里 `_contextId` 是 **`HUDMainApplication` 自己的 ivar**（与 `_drawingContext` 相邻出现在 ivar/属性名表里），**不是** `UIWindow` 的东西。
- 【已证·二进制】复刻的 `__objc_ivar` 表里没有任何 `_contextId` 字段被链接进去，说明 `MFHUDWindow` 没有自己存 contextId。
- 所以第 50 行 `[window respondsToSelector:_contextId]` 在 iOS 16.1 上很可能返回 **NO** → 直接 return NO → 打印「UIWindow 没有 _contextId」。**注意：这条日志你也没看到，回到 §1.1。**

**问题 C（致命）：`_contextId` 为 0 会怎样？**
- 子进程没进前台 → 窗口还没被合成 → 窗口没有 `CAContext` → `_contextId` 返回 **0**（这是 iOS 13+ 的常规行为：窗口只有挂上 scene 才有 context）。
- 于是第 55 行是 `registerWindowWithContextID:0 atLevel:...`。SpringBoard 收到 contextID=0，**不会报错也不会显示任何东西**（它去 cid 表里查不到就忽略）。
- 所以现象完全自洽：**调用「成功」、日志「成功」、屏幕空白。**

**问题 D（小）：内存管理**
第 40 行 `[cls alloc]` 不走 ARC 的 `+alloc` 规则（返回 `id` 且方法名不是标准 `alloc`/`new`/`copy`/`init` 前缀链），ARC 不会为它插 `release` → 每次调用泄漏一个 controller。`[cls new]` 更安全。

**修法方向**：判返回值；不要向 `UIWindow` 要 `_contextId`（应自己持有 context，或在窗口真正上屏后取）；把 hosting controller 长期持有并复用一个实例。

---

#### ◼ 1.4 `hidden` / `alpha` / `backgroundColor`

【已证·源码】逐个核对，**都写对了**：

| 项 | 绘制窗 | 菜单窗 |
|---|---|---|
| `hidden` | `MFHUDAppDelegate.mm:96` = NO | `:119` = NO |
| `opaque` | `:80` = NO | `:105` = NO |
| `backgroundColor` | `:79` clearColor | `:104` clearColor |
| `rootViewController.view.backgroundColor` | `:84` clearColor | `:108` clearColor |
| ImGui 窗口背景 | `MFMenuUI.mm:110-114` `_alpha=0.96`、`SetNextWindowBgAlpha` | 同 |

**唯一可挑的一条**：`MFHUDAppDelegate.mm:81` 给绘制窗设了 `userInteractionEnabled = NO`，但 `:77` 的 `drawWin.ignoresHitTestOverride = YES` 已经让 `hitTest:` 返回 nil 了（`MFHUDAppDelegate.mm:23-26`）。这个 `userInteractionEnabled=NO` 是**多余且有害**的（见 §2.4 的层级问题）。

**结论**：不是这里。**这一项可以从嫌疑列表里划掉。**

---

#### ◼ 1.5 `MFOverlayView` 的 `CAMetalLayer` 能不能出画面

`MFOverlayView.mm:37-44`：
```objc
37:  CAMetalLayer *ml = self.metalLayer;
38:  id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
39:  ml.device = dev;
40:  ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
41:  ml.framebufferOnly = YES;
42:  ml.opaque = NO;
43:  ml.backgroundColor = [UIColor clearColor].CGColor;
```

| 检查项 | 结论 |
|---|---|
| `pixelFormat` | ✅ 与 `imgui_impl_metal.mm:679` 的 `pipelineDescriptor.colorAttachments[0].pixelFormat` 走同一来源，不会有格式不匹配 |
| `framebufferOnly = YES` | ✅ 对 render target + `presentDrawable` 是受支持组合 |
| `isOpaque / opaque` | ✅ NO + `clearColor` alpha=0（`MFOverlayView.mm:112`） |
| `drawableSize` | ✅ `MFOverlayView.mm:51-58` 在 `layoutSubviews` 里按 `bounds × scale` 设，`tick:` 里 `:103` 还有兜底重设 |
| `scale` 取的路径 | ⚠️ `MFOverlayView.mm:53` `self.window.screen.scale` —— 窗口没上屏时 `self.window` 为 nil，会落到 `UIScreen.mainScreen.scale`，**值是对的（iPad 2.0）**，不算 bug |
| **`dev` 未判空** | ❌ **真问题**：`MFOverlayView.mm:38` 拿到 nil 也照样 `ml.device = nil`，然后 `MFImGuiContext.mm:18` `[device newCommandQueue]` 直接返回 nil（不崩），后续每帧 `[self.imgui.queue commandBuffer]` 也是 nil → 静默什么都画不出来。**建议加一次显式判空 + 日志。** |

**结论**：`CAMetalLayer` 这一层没有「必不显示」的硬伤，但有一条**会导致完全静默失败**的判空缺口。**这一项不能排除**，需要真机日志。

---

#### ◼ 1.6 ImGui 上下文初始化会不会失败

【已证·二进制】工程内 ImGui 版本：
```
imgui.h:32  #define IMGUI_VERSION      "1.93.0 WIP"
imgui.h:33  #define IMGUI_VERSION_NUM  19298
```
`io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen)`（`MFImGuiContext.mm:212`）在 `imgui.h:2591` 有声明，`ImGuiCol_TabSelected`（`MFImGuiContext.mm:149`）在 `imgui.h:1815` 有。**版本对得上，不是 API 不存在的问题。**【已证·源码】

`ImGui_ImplMetal_Init` 本身【已证·源码】只做 descriptor 与 backend flags 初始化，真正的 Metal 对象是**懒创建**的：
- `imgui_impl_metal.mm:644-649` `newLibraryWithSource:` 失败 → 返回 nil 并 `NSLog(@"Error: failed to create Metal library: %@")`
- `imgui_impl_metal.mm:654-658` 找不到 `vertex_main`/`fragment_main` → 返回 nil 并 `NSLog(...)`
- `imgui_impl_metal.mm:679` 用 `framebufferDescriptor` 的像素格式建管线

**这条 NSlog 用的是 ASCII，会落在 `__cstring`。我在复刻二进制里搜过整个文件——`failed to create Metal library` 没出现，说明二进制里带这个字符串（能被打印），只是没被触发过。**（注意：`NSLog` 只有在被调用时才输出，字符串存在 ≠ 被调用过。）

**iOS 16.1 兼容性结论**：我没找到任何 `ImGui_ImplMetal_Init` 在 iOS 16.1 上的已知不兼容点。**这一项应当从「可疑」降到「需验证」。**【未证】

---

#### ◼ 1.7 ★ HUD 进程是不是启动后就崩了？`kill(pid,0)` 探活可靠吗？

**你的直觉是对的，但不完全准确。我把它拆成两层：**

**第一层：`kill(pid,0)` 的语义**
【已证·源码】`MFHUDLauncher.mm:29-31`：
```objc
29:  // 探活：信号 0 不发信号，只做存在性检查
30:  if (kill(p, 0) == 0 || errno == EPERM) return p;
31:  return 0;
```
- `kill(pid, 0)` 返回 0 = **该 PID 在进程表里还有一个进程条目**。
- 对**僵尸进程**（已退出、父进程尚未 `waitpid` 回收）返回 **0** —— 你的判断正确。
- 但本工程**没有** `waitpid(pid, ..., WNOHANG)` 也没装 `SIGCHLD` handler（全工程搜 `waitpid`：只有 `docs/复刻总方案.md` 提到，源码里没有），所以**子进程退出后一定会变成僵尸，且永远不会被回收**。
- → **结论：`isHUDRunning` 会在 HUD 进程死亡后继续返回 YES。** 这是一个**确凿的逻辑 bug**，也是「控制台显示运行中」与「屏幕上什么都没有」能同时成立的原因之一。

**第二层：僵住之后会怎样（比僵尸更糟）**
【已证·源码】`MFHUDLauncher.mm:38-42`：
```objc
38:  + (BOOL)startHUDWithError:(NSString **)err {
39:      if ([self isHUDRunning]) {
40:          if (err) *err = @"HUD 已在运行";
41:          return NO;
42:      }
```
既然 `isHUDRunning` 永远返回 YES，**第二次点「启动悬浮窗」会直接失败，你再也拉不起来第二个 HUD 进程**。你现在处于「状态行显示 PID 337，但那个进程要么是僵尸要么是空跑」的死锁态。

【已证·源码】`MFHUDLauncher.mm:87-100` 同类问题：`stopHUDWithError:` 在 `kill` 返回 ESRCH（进程已死）时返回 NO，**但不删 PID 文件** → 状态永远卡在「运行中」。

**修法方向**（明确、可落地）：
1. 用 `waitpid(pid, &status, WNOHANG)` 判活，而不是 `kill(pid,0)`；或者
2. 用 `proc_pidpath(pid, ...)` 校验该 PID 的可执行路径确实是本 App，排除 PID 复用；
3. `kill` 返回 ESRCH 时无条件清掉 PID 文件。

**第三层：怎么才能真正确认它是死是活（给真机的实操）**
```bash
# TrollStore 环境下（或用你自己的进程列表页）：
ps -A -o pid,ppid,state,comm | grep -i findmy
# 关键看 STAT 列：
#   Z  = 僵尸  → 子进程死了，你的探活被僵尸骗了
#   S/T = 睡眠/停止 → 进程活着但没在跑（被 RunningBoard 挂起）
#   R  = 运行  → 活着在跑
```
你工程里本来就有 `MFKernel` 的进程枚举能力（路 B 免特权枚举，见 `docs/复刻版验证状态.md:121`），**用它去枚举 `FindMy` 并读 state，比 `kill(pid,0)` 可靠一万倍**。

---

#### ◼ 1.8 【额外发现·必看】绘制窗层级高于菜单窗 40 → 菜单永远摸不到

这是个**独立于显示问题、但一定会让你误判「测试失败」**的 bug：

- 绘制窗 `makeKeyAndVisible` 在 `MFHUDAppDelegate.mm:97`，层级 `StatusBar + 20`
- 菜单窗 `makeKeyAndVisible` 在 `MFHUDAppDelegate.mm:120`，层级 `StatusBar - 20`

UIKit 的命中测试顺序是**按窗口层级从高到低**。`StatusBar+20 > StatusBar-20`，所以**每次都先问绘制窗**。

而绘制窗：
```objc
MFHUDAppDelegate.mm:77:      drawWin.ignoresHitTestOverride = YES;   // → _ignoresHitTest / hitTest: 都返回 nil
MFHUDAppDelegate.mm:23-26:   hitTest: → if (ignoresHitTestOverride) return nil;
MFHUDAppDelegate.mm:81:      drawWin.userInteractionEnabled = NO;
```

【推断】UIKit 在某一层窗口 `hitTest:` 返回 nil 时**不会继续往下找更低层级的窗口**（同一窗口内部才会继续往兄弟视图找）。这会让所有触摸都到不了菜单窗。**这一条必须真机验证**（验证方法见 §4.2），但如果成立，它的后果是：菜单可能**已经在屏幕上**，你只是没法拖它、没法点它，加上它本身画在透明层下面，看起来就是「不存在」。

另外，`MFOverlayView.mm:133-137` 的 `pointInside:` 有个**鸡生蛋**：
```objc
133: - (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
134:     if (!self.interactive) return NO;
135:     if (CGRectIsNull(self.captureRect)) return NO;   // 还没拿到面板矩形
136:     return CGRectContainsPoint(self.captureRect, point);
137: }
```
`captureRect` 由 `MFMenuUI.mm:108` 每帧设置：
```objc
108: overlay.captureRect = CGRectMake(_pos.x, _pos.y, ws.x, ws.y);
```
也就是说 —— **只有菜单真的渲染过一帧之后，触摸才会被接收**。如果渲染链任何一环断了，`captureRect` 永远是 `CGRectNull`，触摸永远不进来，而触摸不进来你也无法通过「点一点试试」来判断它是不是在渲染。**这是个典型的自锁设计，建议加一条：菜单首次渲染成功后写一个文件标记 + 主界面显示。**

---

### 二、HUD 进程真的是独立的吗

#### ◼ 2.1 `posix_spawn` 自派生

【已证·源码】`MFHUDLauncher.mm:44-63`：
```objc
44:  NSString *exe = [NSBundle mainBundle].executablePath;
50:  const char *path = exe.fileSystemRepresentation;
51-54: argv = { path, "-hud", NULL }
57:  int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
```

**技术上可行**：
- 【已证·二进制】`posix_spawn` 在 `MobileStore`（原版）里出现 **24 次**、`waitpid` 出现 2 次 —— **原版就是这么干的**。所以「同 bundle 起第二个进程」在 TrollStore 下是可行的，这条路本身没问题。
- 【已证·二进制】复刻的 `posix_spawn` / `kill` 都正常链接，导入符号表里有。

**但有 4 个缺陷：**

| # | 位置 | 问题 | 后果 |
|---|---|---|---|
| a | `MFHUDLauncher.mm:57` | `posix_spawnattr` 传 NULL，**没有 `POSIX_SPAWN_SETSID`** | 子进程留在父进程的 session 里；父进程被杀时子进程可能陪着走。原版据 `_installEventRunLoopSources:` 看，事件循环是自己接的【已证·原版】，不是靠继承 |
| b | `MFHUDLauncher.mm:57` | `posix_spawn_file_actions` 传 NULL | 子进程**继承父进程当时的所有 fd**。`MFKernelBridge.m:206-207` 的 `dup2(fd, STDOUT_FILENO)` 一旦在那之前发生过，子进程的 stdout/stderr 就指向父进程的 `Documents/mf_kfd.log`【已证·源码】 |
| c | `MFHUDLauncher.mm:79-83` | `usleep(400ms)` + `kill(pid,0)` | 见 §1.7：僵尸也返回 0 |
| d | 全工程 | **无 `waitpid`、无 `SIGCHLD`** | 僵尸永久累积 |

#### ◼ 2.2 `main.mm` 的分流逻辑

【已证·源码】`main.mm:14-23`：
```objc
14:  static BOOL MFIsHUDLaunch(int argc, char *argv[]) {
15:      for (int i = 1; i < argc; i++) {
16:          if (!argv[i]) continue;
17:          if (strcmp(argv[i], "-hud") == 0 ||
18:              strncmp(argv[i], "-hud", 4) == 0) {
19:              return YES;
20:          }
21:      }
22:      return NO;
23:  }
```

**会不会误判？—— 会，而且是「本 bug 无关但迟早炸」的那种。**

| 输入 | `strncmp(s,"-hud",4)==0` | 结果 |
|---|---|---|
| `-hud` | ✅ | 命中（本意） |
| `-hud1` / `-hud2` / `-hud3` | ✅ | 命中。但**源码里从没传过这三个**（`MFHUDLauncher.mm:53` 只传 `-hud`），而 `MFHUDLauncher.h:5` 的注释还写着「参数为 -hud / -hud1 / -hud2 / -hud3」——**注释与实现不一致**【已证·源码】 |
| `-huds`,`-hudXYZ`,`-hudWhatever` | ✅ | **误命中** |
| `-hu` | ❌ | 不命中（正确） |

**风险评估**：iPhoneOS 的 `argv` 里常见的有 `-AppleLanguages`、`-NSDocumentRevisionsDebugMode`（macOS 才有）等；iOS 上 SpringBoard/FrontBoard 传入 `-hud` 开头的参数**我没在本机证据里见到**。所以**当前不构成实害**【推断】。但 `strncmp(...,4)==0` 完全被 `strcmp(...,"-hud")==0` 覆盖，是纯冗余 + 纯风险。**建议删掉第 18 行。**

#### ◼ 2.3 能不能同时跑两个进程？有没有更可靠的做法？

- **能。** 【已证·二进制】原版就是 `posix_spawn` 自派生（24 处引用）。bundle ID 相同不影响：iOS 的「一个 App 一个进程」约束是 **FrontBoard 的 App 生命周期管理**层面的，`posix_spawn` 绕过了它，代价就是**新进程不被当作前台 App** —— 这正是 §1.2 的病根。
- **更可靠的做法 1（推荐）**：**不要让 HUD 当第二个 App。** 原版的 `_addTouch:forDelayedDelivery:` + `_enqueueHIDEvent:`【已证·原版】暗示它是把 HID 事件**投递给另一个进程/自己维护的事件环**，而不是靠 UIKit 的前台窗口。可以考虑反过来：**在主进程（真前台）建窗 + 托管**，HUD 进程只负责数据。
- **更可靠的做法 2**：`UIApplication` 的 scene session。若要保留双进程，就必须把 §1.2 那层 `UIApplication` 子类补上，让子进程通过 `_accessibilityInit` 之类的私有初始化把窗口服务器连接建立起来。
- **不推荐**：`UIScene` 的多场景（`UISceneSessionRole`）——它需要一个被 FrontBoard 管理的 App，`posix_spawn` 的进程不满足前提。

#### ◼ 2.4 容器 / Documents

【已证·源码】
- 两个进程的可执行文件是**同一个 bundle 路径**（`MFHUDLauncher.mm:44`）。
- 在 TrollStore + `com.apple.private.security.no-sandbox` 下，**两个进程的 `NSDocumentDirectory` 是同一个真实路径**（同一个 bundle container），**能读写同一份 `mf_settings.plist` / `mf_kfd.log`**。
- 【已证·二进制】原版 Info.plist 里有 `CFBundleURLTypes`（scheme `MobileStore`），复刻**没有**。如果后续要做主进程↔HUD 进程通信，这条 URL scheme 是最省事的通道，建议补上。

**⚠️ 顺带一个会咬人的点**：两个进程共用 `MFSettings`（`MFSettings.mm:108` save / `:154` load）和 `Documents/mf_settings.plist`。**HUD 进程里在 ImGui 里改设置 → save；主进程随后 save → 覆盖。** 现在没做任何跨进程锁。见 §5 问题 11。

---

### 三、为什么 syslog 里看不到 NSLog

#### ◼ 3.1 先定性：日志代码在二进制里，一条没少【已证·二进制】

我把 `dist/FindMy-M4.3.ipa` 里的 `FindMy` 解出来按 section 扫过：

- `__TEXT,__cstring`（ASCII）里只有 `[MF][Kernel] kern.version = %@` 一条 `[MF]`
- **其余全部落在 `__TEXT,__ustring`（UTF-16LE）里**，包括：

```
[MF][HUD] didFinish，开始建立双窗口
[MF][HUD] 绘制窗渲染启动失败: %@
[MF][HUD] 菜单窗渲染失败启动失败  ← （原串：菜单窗渲染启动失败: %@）
[MF][HUD] 托管结果：菜单窗=%d 绘制窗=%d
[MF][HUD] ⚠️ 两个窗口都托管失败 —— 检查 accessibility-window-hosting 权限是否生效
[MF][HUD] 进入后台 / 回到前台
[MF][HUD] 找不到 SBSAccessibilityWindowHostingController
[MF][HUD] 托管控制器不支持 registerWindowWithContextID:atLevel:
[MF][HUD] UIWindow 没有 _contextId
[MF][HUD] 已托管窗口 contextId=0x%x level=%.0f
[MF][HUDLaunch] 已拉起 HUD 进程 pid=%d / 已结束 HUD pid=%d
[MF][Overlay] ImGui 初始化失败: %@ / 渲染已启动 (interactive=%d, %.0fx%.0f) / 帧率 %ld → %ld
[MF][ImGui] 上下文就绪 (device=%@) / 字体已加载 / 找不到字体资源 / AddFontFromFileTTF 返回空
[MF] 以 HUD 角色启动
```
`__ustring` 共 304 条；`@_contextId`、`@-hud`、`@/var/mobile/Library/Caches/mf.findmy.hud.pid` 也都在。

**→ 结论：日志不是「被裁掉的」。syslog 里没有输出，意味着代码没跑到那儿，或者进程根本没走这个 `main()`。**

#### ◼ 3.2 有没有机制让 App 的 NSLog 进不了 syslog？

**有，三条，按可能性排序：**

1. **进程的 stderr 没有接线**。iOS 上 App 的 `NSLog` 是走 stderr，由 `launchd`/syslog 收集的。`posix_spawn` 出来的子进程**不是**由 SpringBoard/FrontBoard 启动的，其 stderr 可能直接挂到父进程的 stderr（或者 `/dev/null`）。**这一条对本案高度相关**【推断】。
   - 旁证：`MFHUDLauncher.mm:57` **没有** `posix_spawn_file_actions` → 子进程 100% 继承父进程的 fd 0/1/2【已证·源码】。
   - 如果父进程此前被重定向过（下一条），子进程的 stderr 也跟着过去了。

2. **★ `mf_redirect_klog()` 会截断 stdout/stderr**【已证·源码】`MFKernelBridge.m:194-212`：
   ```objc
   194: static void mf_redirect_klog(void) {
   196:     if (g_klog_fd >= 0) return;
   198:     NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, ...);
   202:     NSString *path = [docs stringByAppendingPathComponent:@"mf_kfd.log"];
   203:     int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0644);
   206:     dup2(fd, STDOUT_FILENO);
   207:     dup2(fd, STDERR_FILENO);
   208:     g_klog_fd = fd;
   210:     printf("[mf] ==== kfd log opened  pid=%d  puaf/landa 前置日志 ====\n", getpid());
   ```
   **触发时机**：只在 `mf_kopen()` 里被调用（`MFKernelBridge.m:239`）。`mf_kopen` 的调用点只有 `MFKernel.mm:147`。

   **所以准确回答你的问题：**
   - ✅ **会不会把 NSLog 挟走？** —— `dup2` 换的是**进程级 fd 0/1/2**。`NSLog` 在当前 SDK 上是走 `os_log`/`ASL`（不经过 fd 2）还是写 stderr，我**没有设备证据**。**这一点必须真机验证。**【未证】
   - ✅ **什么时候触发？** —— **只在主进程点了「启动内核」并执行到 `MFKernel.mm:147` 的那一刻**。
   - ⚠️ **对本 bug 的实际影响：很小。** 顺序上，HUD 进程是在用户点「启动悬浮窗」时派生的；如果此前没点过「启动内核」，重定向没发生，HUD 子进程的 fd 是干净的。
   - ⚠️ **但是有个副作用是确定的**：`O_TRUNC`（`MFKernelBridge.m:203`）——**每次 `mf_kopen` 都把上一次的内核日志清空**。「启动内核」→ 重启 App → 再启动内核，日志就没了。这是个独立缺陷。

3. **Release 构建 + Release scheme 跑**（`.github/workflows/build.yml:36` `-configuration Release`）。【已证·二进制】我核对过：**日志字符串全在**，Release 没有裁它。所以这条**不是**原因。

#### ◼ 3.3 更可靠的日志渠道（建议直接加）

| 方案 | 可行性 | 说明 |
|---|---|---|
| **写文件（首选）** | ✅ | `[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory...) firstObject]` + `stringByAppendingPathComponent:@"mf_hud.log"`，用 `NSFileHandle` 追加；**路径与 `mf_kfd.log` 同目录**，主界面「内核日志」页已有读取器（`mf_read_klog()`，`MFKernelBridge.m:215-230`）可直接复用改成通用 `mf_read_log(名字)` |
| **主界面回显** | ✅ 最直观 | HUD 子进程启动后，主进程轮询这个日志文件，把最后 N 行显示在「悬浮窗（HUD）」那一行（`RootViewController.mm:98-103`） |
| `os_log` + `log stream` | ⚠️ | 需要 `os_log_create` + 设备端 `log stream --predicate`；在 TrollStore 下同样受「进程是否被 syslog 认领」影响，不如写文件稳 |
| `NSLog` 继续用 | ❌ | 本次就是这样翻车的 |

**具体建议（我不改代码，你自己加）**：在 `MFHUDAppDelegate.mm:71` 之后、**第一件事**就是往 `Documents/mf_hud.log` 写一行带 `getpid()` 的时间戳；在 `main.mm:27` 进 HUD 分支时也写一行。**这两行就能立刻把「进程没起来」「进程起来了但 delegate 没被调」区分开** —— 这是当前最缺的那块拼图。

---

### 四、其它发现

| # | 位置 | 问题 | 严重度 | 修法 |
|---|---|---|---|---|
| 8 | `MFHUDAppDelegate.mm:40` | `[cls alloc] + objc_msgSend(init)`：ARC 不会插 release（返回类型 `id` + 非常规 alloc 链） | 低（泄漏） | 改 `[cls new]` |
| 9 | `MFHUDAppDelegate.mm:55-59` | hosting 接口返回值被丢弃，失败也报 YES | **中** | 判返回值 + 打日志 |
| 10 | `MFHUDAppDelegate.mm:34-60` | 每次调用都新建一个 `SBSAccessibilityWindowHostingController`，用完不持有 | 中 | 提成 `MFHUDAppDelegate` 的强引用属性；原版是 `_drawingHostingController` + `_MenuHostingController` 长期持有【已证·原版】 |
| 11 | `MFSettings.mm:108/154` | 两个进程共写 `Documents/mf_settings.plist`，无跨进程锁 | 低 | 写入前用 `O_EXLOCK` 或写临时文件 + `rename` 原子替换 |
| 12 | `MFOverlayView.mm:38` | `MTLCreateSystemDefaultDevice()` 未判空，nil 会静默全链路失效 | **中** | 判空 + 明确 fail 日志（不要静默） |
| 13 | `MFOverlayView.mm:84-90` | `CADisplayLink` 持有 target（self）→ **强引用环**；`stopRendering`（`:93`）只在 `didMoveToWindow:` 里 window 变 nil 时才调（`:66`） | 中 | 用 `NSProxy`/弱包装或 `-invalidate` 时机保证；ARC 下 `CADisplayLink` 是已知的循环引用源 |
| 14 | `MFOverlayView.mm:100` `:117` | 每帧都调 `self.window.screen.scale`，窗口为 nil 时每帧回落 `UIScreen.mainScreen.scale` | 低 | 缓存 scale，`didMoveToWindow` 时更新 |
| 15 | `MFHUDAppDelegate.mm:97` + `:120` | 两个窗口先后 `makeKeyAndVisible`，第二个会夺走 key window 状态，恰好又会**再触发一次合成** | 低 | 只需其中一个 `makeKeyAndVisible` |
| 16 | `main.mm:18` | `strncmp(argv[i],"-hud",4)==0` 前缀误判（见 §2.2） | 低（当前） | 删掉 |
| 17 | `MFHUDLauncher.mm:87-100` | `kill` 失败不删 PID 文件 → 状态永久卡「运行中」 | **中** | 见 §1.7 |
| 18 | `MFHUDLauncher.mm:29-31` | `kill(pid,0)` 判活不可靠（僵尸/PID 复用） | **高** | 见 §1.7 |
| 19 | `MFKernelBridge.m:203` | `O_TRUNC` 清空历史 klog | 低 | 改 `O_APPEND` |
| 20 | `MFHUDAppDelegate.mm:135-142` | `dispatch_after` 0.35s 后托管。**这个 0.35s 是拍脑袋的**，如果窗口此时还没上屏，`_contextId` 必为 0 | **中** | 改成「等窗口真正上屏」的事件（`UIWindowDidBecomeVisibleNotification`）或重试循环 |
| 21 | `MFHUDAppDelegate.mm:14-28` | 注释声称覆写了 4 个私有属性，`MFHUDWindow` 实际只判了 `hitTest:`；`_ignoresHitTest` 直接返回了 `ignoresHitTestOverride` 的当前值（`:20`） | 低 | 注释与实现对不上，容易误导 |
| 22 | `MFMenuUI.mm:79-82` | `!gVisible \|\| !s.masterEnabled` 时清空 `captureRect`，配合 §1.8 的 `pointInside:`，形成「渲染没成功→点不到→无法自检」的死循环 | 中 | 加一个首次渲染成功的落盘标记 |
| 23 | `MFImGuiContext.mm:42-45` | `ImGui_ImplMetal_Init` 失败只 `return NO`，**没有走 `ImGui::DestroyContext`**，`_ctx` 泄漏且 `_initialized` 保持 NO | 低 | 失败分支补 `DestroyContext` |
| 24 | `MFHUDAppDelegate.mm:66-67` | `gIsHUD` 是文件级 static，`+isHUDProcess` 全工程无调用点 | 低 | 无害，但说明这套「角色判定」设计没被用起来 |
| 25 | 全工程 | HUD 进程里没有暂停/退出渲染的路径；**用户点「结束悬浮窗」只发 SIGTERM**（`MFHUDLauncher.mm:93`），`MFOverlayView` 没有 `applicationWillTerminate` 处理 | 低 | SIGTERM 默认会直接杀进程，问题不大；但若进程已在僵尸态，SIGTERM 也杀不动 |
| 26 | `Info.plist` | 缺 `UIApplicationSystemWindowsSecureKey`、`UIApplicationShowsViewsWhileLocked`、`UILaunchStoryboardName`、`CFBundleURLTypes` —— **原版全都有**【已证·原版】 | 中 | 逐条对齐；特别是 `UIApplicationSystemWindowsSecureKey`（与 `_isSecure`/`_shouldCreateContextAsSecure` 那套配套） |

---

## 3. 已证 / 推断 / 未证 分级汇总

### 【已证·二进制】（从已打包 IPA 里直接读出，最硬）
1. HUD 全部日志字符串（UTF-16）在二进制里，**没被裁**
2. `MFHUDWindow` / `MFHUDAppDelegate` / `MFHUDLauncher` / `MFImGuiContext` / `MFMenuUI` / `MFOverlayView` 全部编译进去了，方法体地址可列
3. `__objc_classlist` 里有 `MFHUDWindow`、`MFHUDAppDelegate`（`:69-145` 有 `didFinishLaunching` 实现）
4. `Info.plist` 无 `UIApplicationSceneManifest`；二进制里也无相关字符串
5. 二进制里**没有**任何 `UIApplication`/`UIWindow` 子类（除 `MFHUDWindow`）
6. 导入符号表里有 `_UIWindowLevelStatusBar`、`_MTLCreateSystemDefaultDevice`、`_NSLog`、`_OBJC_CLASS_$_UIWindowScene`
7. 打包产物 `FindMy-M4.3.ipa` / `FindMy-unsigned.ipa` / `m43.zip` 内是**同一份** exe

### 【已证·原版】（从原版 `MobileStore` 读出）
8. 原版**也没有** Scene manifest —— 排除「Scene 是本 case 的关键」
9. 原版有 `HUDMainApplication`、`MainApplication`、`HUDMainApplicationDelegate`、`_accessibilityInit`、`_installEventRunLoopSources:`、`_enqueueHIDEvent:`、`_drawingHostingController`、`_MenuHostingController`、`_drawingContext`、`_isWindowServerHostingManaged`
10. 原版 **`_contextId` 是自己的 ivar**，不是 `UIWindow` 的
11. 原版用 `posix_spawn` 自派生（24 处引用）+ `waitpid`（2 处）——**原版会回收子进程，复刻不会**
12. 原版 `Info.plist` 有 `NSPrincipalClass=HUDMainApplication`、`UIApplicationSystemWindowsSecureKey=True`、`CFBundleURLSchemes=MobileStore`、`UILaunchStoryboardName=LaunchScreen`

### 【已证·源码】
13. `MFHostWindow` 丢弃返回值、0.35s 硬编码、`[cls alloc]` 泄漏
14. `kill(pid,0)` 判活 + 无 `waitpid` → 僵尸被当存活
15. `strncmp(...,"-hud",4)` 前缀误判
16. 绘制窗（+20）压在菜单窗（−20）之上；且 `pointInside:` 依赖 `captureRect`，形成自锁
17. `mf_redirect_klog()` 用 `dup2` 换 fd 1/2 且 `O_TRUNC`；只在 `mf_kopen` 里调
18. `MFOverlayView.mm:38` 未判 Metal device 空
19. HUD 子进程 `posix_spawn` 无 file_actions / 无 attr

### 【推断】（有依据，需真机确认）
20. 子进程拿不到 `UIWindowScene` → 无 `CAContext` → `_contextId = 0` → 注册了也不显示（~70%）
21. UIKit 不会把被高层窗口 `hitTest:` 吞掉的触摸转发给低层窗口（~75%，但需要验证）
22. 子进程可能在 `UIApplicationMain` 内部阻塞，从未进入 delegate（~50%）
23. 子进程可能被 RunningBoard 挂起（~30%）

### 【未证】（我不知道，别当我编的）
24. `UIWindow` 在 **iOS 16.1** 上到底有没有 `_contextId` 这个 selector（原版是自己 ivar，`NSClassFromString` 那侧就无从得知）
25. `NSLog` 在 iOS 16.1 上是否走 stderr（决定 `dup2` 会不会挟走它）
26. `registerWindowWithContextID:0` 的确切行为（我推断是静默忽略，没实证）
27. HUD 子进程此刻究竟是 僵尸 / 挂起 / 运行
28. ImGui 渲染链在设备上是否已经成功出过一帧

---

## 4. 可验证的假设 · 怎么验（具体到看哪个日志/哪个按钮）

### 4.1 ★ 第一步（必做，成本最低）：给 HUD 链装「黑匣子」

**为什么**：现在所有结论都卡在「不知道子进程走到哪」。先解决可观测量，再谈修。

**加什么**（3 个点，都在 HUD 侧）：
| 位置 | 写什么 |
|---|---|
| `main.mm:27` `if (MFIsHUDLaunch(...))` 成立的分支第一条 | 写文件：`HUD child main() entered, pid=<getpid()>, ppid=<getppid()>` |
| `MFHUDAppDelegate.mm:71` 之后 | 写文件：`didFinishLaunching entered` |
| `MFHUDAppDelegate.mm:106` 之后（两个 window 都建完） | 写文件：`windows created: drawWin=<addr> menuWin=<addr> drawWin.windowScene=<ptr> drawWin.hidden=<bool>` |

**新增一个检查项**（这是本报告最想知道的一个数）：
```objc
// 临时诊断，打完就删
NSLog/log(@"drawWin.windowScene = %@", drawWin.windowScene);          // nil = 没有 scene
NSLog/log(@"drawWin._contextId  = %d", ctxId);
NSLog/log(@"drawWin.hidden=%d, windowLevel=%.0f", drawWin.hidden, drawWin.windowLevel);
NSLog/log(@"UIApplication.sharedApplication.applicationState = %ld", (long)[UIApplication sharedApplication].applicationState);
```
- `applicationState` 若是 `UIApplicationStateBackground(2)` → **证实**子进程没进前台（对应 §1.2）
- `windowScene` 若是 `nil` → **证实**窗口没挂 scene（对应 §1.2）
- `_contextId` 若是 `0` → **证实**注册的是空 context（对应 §1.3）

**写完怎么看**：主界面加个「读 HUD 日志」的按钮，复用 `mf_read_klog()`（`MFKernelBridge.m:215`）那套读文件逻辑，改成读 `mf_hud.log`。

### 4.2 判断进程死没死（不用装任何工具）

1. 主界面点「启动悬浮窗」→ 记下 PID
2. 用工程自带的能力探测枚举进程（`docs/复刻版验证状态.md:121` 的路 B），找 `FindMy`，**看同名进程有几条、state 是什么**
   - 有两条（父 PID + 子 PID）：子进程活着
   - 只有一条：**子进程已经死了**，你看到的「运行中」是僵尸骗的 → 证实 §1.7
3. 或 `ps -A -o pid,ppid,state,comm | grep -i findmy`，看 `STAT` 列是不是 `Z`

### 4.3 验证「绘制窗压住菜单窗」的触摸问题（§1.8）

**方法（不用改代码，最快）**：
1. 点「启动悬浮窗」
2. 在屏幕上**原来菜单应该出现的位置（约 `(24, 90)` 起 348×520 的矩形）**用手指划一下、点几下
3. 如果菜单**已经在渲染**，它会有反应（能拖动、能点「隐藏」）——只是你看不见，因为它被绘制窗的透明层盖着
4. 若要看得见：把 `MFMenuUI.mm:67` 的 `_alpha = 0.96f` 临时改成 `1.0f`，或把 `MFHUDAppDelegate.mm:78` 的 `+20` 临时改成 `-40`（**让菜单窗层级更高**）

**如果拖不动** → 证实 §1.8 的触摸拦截。
**如果拖得动但看不见** → 说明窗口**确实上了屏**，问题只在「菜单窗层级太低 / 绘制窗遮挡」→ 修正嫌疑排序。

### 4.4 验证渲染链是否已经出过一帧

在 `MFOverlayView.mm:127`（`[cb commit]`）之后加一行**一次性**写文件：
```objc
// 只在第一次写
NSFileHandle 追加: "[HUD] first frame committed at <time>, drawable=%p, size=%.0fx%.0f"
```
- **文件出现** → Metal/ImGui 链是通的，问题 100% 在「窗口没上屏」
- **文件不出现** → 渲染链自己就断了，去查 `MFOverlayView.mm:38`（device 为空）、`imgui_impl_metal.mm:644-697`（管线/着色器）、`MFOverlayView.mm:100`（bounds 为 0）

### 4.5 验证是否被挂起

「启动悬浮窗」→ **把主 App 切到后台**（回桌面）→ 等 30 秒 → 回主 App 看那个 `mf_hud.log` 的**最后写入时间**：
- 时间戳一直在走 → 没被挂起
- 时间戳停住不动 → **被挂起了** → 需要加 `UIApplication` 的 background task 或改架构

---

## 5. 建议的修复顺序（如果按我的判断走）

1. **先加 4.1 的黑匣子日志**（写文件，不用 syslog）—— 不做这步，后面全是猜
2. **修 §1.7 的探活**（`waitpid` + PID 文件清理）—— 否则你连重试都做不了，每次测试要重装 App
3. **修 §1.8 的层级（菜单窗压过绘制窗）**—— 让「菜单到底在不在」这个观测变成可能
4. **按 §4.3 的对比实验拿到 `windowScene` / `_contextId` / `applicationState` 三个数**
5. 若证实是 scene / 前台问题 → **补 `UIApplication` 子类那一层**（对齐原版的 `HUDMainApplication` + `_accessibilityInit`），或改架构（改为「主进程建窗 + 子进程只供数据」）
6. 顺手把 §5 表格里 #9/#10/#12/#13/#17/#18/#20 一次修掉

---

## 6. 我要明确说的两件事（避免误导）

1. **`Info.plist` 缺 `UIApplicationSceneManifest` 不是本 case 的答案。** 原版也没有，原版能显示。我在报告里花篇幅讲它，是因为你点名问了，而且它是「为什么 `UIWindow` 挂不上 scene」这个机理的一部分；**但你如果只是去 Info.plist 里加这个键，八成还是不出窗口。** 真正的缺口在 §1.2 表格里那几行「原版有 / 复刻没有」。

2. **本报告里所有涉及「设备实际发生了什么」的判断，都是【推断】或【未证】。** 我能做到 100% 确证的只有两件事：**(a) 已打包 IPA 里 HUD 代码和日志字符串全都在；(b) 原版用的是 `HUDMainApplication` + hosting controller 那一套，复刻没有。** 剩下的都需要你按 §4 把黑匣子日志补上之后才能定案。

---

*本报告只做只读审查，未修改任何源码。*
