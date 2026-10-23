# 白米饭复刻 · FindMy

一个 iOS 工具 App：**伪装成系统「查找」**，带主界面控制台、悬浮 HUD（C++ ImGui/Metal）、内核读取链与系统清理功能。
当前核实设备：**iPad14,4 / J618AP / 2022 款 11 英寸 iPad Pro M2（蜂窝网络版）· iPadOS 16.1**。历史 M5.72 等测试使用的是 iPad8,11 / A12Z · iPadOS 16.6.1；此前交接报告将 iPad14,4 写成 mini 6 / A15 是错误的。源码在 Windows 上维护，Apple SDK 编译与 simulator 回归在 GitHub Actions macOS 执行。

> 本工程为**独立重写**，参考对象是 `白米饭无验证.ipa` 的静态逆向分析结论（见 `docs/复刻总方案.md` §3）。
> 不含任何授权校验、联网上报或设备指纹采集。

---

## 当前进度

### 2026-10-24：M5.91 绘制入口修复

已修复 `MFDrawingLayer` 在本地读取未就绪时提前返回、使独立外部 UDP 数据源也无法启动的问题。新包：`dist/drawing-fix-M5.91/FindMy-M5.91-DrawingFix.ipa`，包内版本 `b05aec3-r91`。新增真实 UDP→生产绘制→ImGui 回归，修复前实际失败，修复后收到合成包并生成非空顶点。7 套回归最终均取得通过结果，其中 `game-reader` 首轮模拟器未生成结果，单项重试通过；原始失败证据保留。构建与验证详情见 [绘制排查与验证](docs/绘制排查与验证-2026-10-24.md)。

真机 M5.90 的内置合成自检已观测到非空图形及 GPU 提交。用户本轮暂不方便进入游戏场景，因此**新包尚未覆盖安装、真实游戏数据绘制尚未验收**。原外部推流脚本还存在 Frida 17 API 不兼容和布局未同步问题；本轮未修改该脚本。不要把构建成功、合成测试或 GPU 首帧完成写成游戏链已打通。根目录 `dist/FindMy-unsigned.ipa` 是旧 M5.55，请使用上述带版本的路径。

### 历史 HUD 修复与回档记录

此前 HUD 修复位于 `fix/hud-reliability`，**曾按用户要求回档到 M5.72 / `7629429-r72` 的应用与资源，M5.73 / `07617ea-r73` 已撤回**。用户确认M5.73下层App可以操作，但整个悬浮面板失去响应；两次新鲜USB日志均确认该版HUD完成首帧/ready后没有AX触摸跟踪。全窗口忽略命中后的HID持续投递未通过真机验证，停止继续尝试该方案。

回档直接使用用户此前已安装并认可流畅性的原M5.72包：`dist/hud-reliability-M5.72/FindMy-M5.72-HUD.ipa`，地址 `http://192.168.2.6:8189/FindMy-M5.72-HUD.ipa`。本轮重新检查IPA和完整GET，大小/哈希均匹配；未重新打包。源码app/assets精确等同 `762942927780bf758cb0bfa5fb4cc464ea206cba`，回归夹具恢复为M5.72原状态。控制台“结束悬浮窗”后通过TrollStore覆盖安装；iPad上的实际回档安装仍待用户完成。

M5.72沿用完整触点index、收球、退出重启、安全画布、渲染/GPU队列和高刷方案。恢复菜单内正常响应的原输入方式，不再承诺菜单与下层App同次响应。截图/录屏排除与实际高刷仍待物理验证。M5.71保持撤回，8188未恢复；M5.73的8190分发进程已核对并停止。此前六套模拟器回归确实通过，但没有覆盖系统向全放行窗口的进程持续投递触摸，不抵消真机失败。

### M5.74 数据链接线修复（未提交真机验收）

用户反馈「数据好像链接不上」后定位到**接线错误，不是权限或游戏版本问题**：

项目里有两条读游戏的链，能力完全不同 ——

| 链 | 起点 | 能否自动建立 |
|---|---|---|
| `MFUEReader` | 模块基址 + GWorld 静态偏移（模块定位自动拿到 libBase） | **能**。「一键开始」跑的就是它 |
| `MFGameReader` | `rootObjectBase` / `entityArrayBase` / `lootArrayBase` 三个**手工校准**的绝对地址 | 不能。它自己的头文件写着「当前尚无基址校准 UI」，全工程没有任何地方能给这三个值赋值 |

而绘制层（`MFDrawingLayer`）接的是 `MFGameReader`：三个基址恒为 0 →
`readCamera:` 在 `followChain(0)` 处直接返回 NO → `cameraOK` 恒为 false →
绘制层每帧 `return` → **悬浮窗上永远什么都没有**。

同时 HUD 侧还有一个断点：`refreshTargetBinding` 绑定成功时只设了 `MFGameReader.targetTaskPort`，
从来没有恢复过 `MFUEReader.libBase`（只在清理路径把它置 0）。HUD 是独立进程，
控制台写下的 `mf.game.libbase` 不会自动生效。

修复：

- `MFHUDAppDelegate.refreshTargetBinding`：绑定成功后**自己**做模块定位（HUD 有 task port，
  可直接读目标 dyld），失败再退回控制台记录的值，然后写进 `MFUEReader.libBase`。
- `MFDrawingLayer`：数据源改为「已校准的白米饭链优先，未校准时自动落到 UE4 链」。
  UE4 链提供相机 + 全 Actor 坐标（人物框、距离、背敌提示可用）；物资分级、
  队伍、血量这些字段仍需要 `MFGameReader` 那条链被校准后才有。
- Actor 列表是**整个关卡**的（静态物件也算），逐个读会让主线程炸掉 ——
  所以：指针数组每秒重读一次、坐标按每帧 320 个预算轮转、世界坐标缓存 1 秒、
  投影用当前相机每帧重算，并加「盒子距离」上限做距离闸。

`hud.log` 里现在能直接读到断点：`HUD 侧模块定位：libBase=0x…`、
`[绘制] UE4 链未通：<具体哪一步>`、`UE4 缓存：Actor 指针 N 个 · 坐标 M 个`。

- [本轮 HUD 稳定性修复与验收](docs/HUD稳定性修复与验收-2026-10-16.md)：现场旧 PID 误认、根因、修复、实际测试及安装记录。
- [回档M5.72](docs/HUD回档M5.72-2026-10-16.md)：M5.73真机输入失败、证据边界、撤包与精确回档。
- [同次触摸双响应](docs/HUD同次触摸双响应-2026-10-16.md)：已撤回方案的参考核对与自动回归历史，不作为现行交付。
- [功能差距审查](docs/功能差距审查-2026-10-16.md)：真实名称、骨骼、物资分类、偏移、UE4 衔接及 root 业务等剩余缺口。
- 安装包与实际版本/源码/哈希均存入 `dist/` 独立目录。M5.69、M5.71、M5.73的已确认缺陷按各阶段报告保留追溯，当前回档使用M5.72原包。

下表是 M0–M4 的历史源码与构建里程碑，功能可用性以当前审查和逐项设备结果为准。

| 里程碑 | 内容 | 状态 | 构建 |
|---|---|---|---|
| **M0** | 伪装壳 + 云构建管道 + entitlements 自检 | ✅ | #2 |
| **M1** | 主界面控制台 + 清理系统残留 + 清理 Key + 防封 + 游戏模式 | ✅ | #5 |
| **M2** | `-hud` 自派生 + 双窗口托管 + ImGui 三页菜单 | ✅ | #9 |
| **M3** | KFD 内核链（kfund 运行时 patchfinder + landa + task 枚举） | ✅ | #15 |
| **M4** | 读取后端 + 投影 + ESP 绘制层 | ✅ | #17 / #18 |

📋 **[复刻版验证状态](docs/复刻版验证状态.md)** —— 哪些已证、哪些未证、哪些做不到（诚实盘点）
📋 **[kfd-移植清单](docs/kfd-移植清单.md)** —— 20 文件闭包 + 7 处 patch + 风险清单

### 历史待验收项目（M5.72–M5.74）

以下保留当时的排查记录；当前交付和已验证范围以顶部 M5.91 说明及本轮验证报告为准。

- ⏳ **回档后设备确认** —— 覆盖安装M5.72后，确认面板点击、拖动和收球恢复；此前流畅性认可保留。
- ⏳ **M5.74 数据链真机确认** —— 装新包后看 `hud.log`：`HUD 侧模块定位` 是否拿到 libBase、
  `[绘制] UE4 链未通` 有没有出现、悬浮窗上是否出现人物框。
- ⛔ **游戏偏移校准（部分解除）** —— 相机/玩家/Actors 这条链已接上并且**可自动建立**；
  剩下的物资分级、真实名称、队伍/血量/武器字段、骨骼拓扑仍需目标游戏本体的逆向结果。

### 本地自检

```bash
python -X utf8 scripts/preflight.py # 本轮 168 项通过，Windows 使用 UTF-8 输出
python scripts/verify_ipa.py dist/drawing-fix-M5.91/FindMy-M5.91-DrawingFix.ipa # 本轮新包验货（含 entitlements 逐条核对）
python scripts/make_icon.py        # 重新生成图标
python scripts/make_font.py        # 重新生成中文子集字体（加了新文案就跑一遍）
python scripts/serve_ipa.py        # 局域网分发 IPA，iPad 上 Safari 直接下
```

---

## 伪装身份

| 字段 | 值 |
|---|---|
| 显示名 | **查找** |
| Bundle ID | `com.apple.findmy` |
| 可执行文件 | `FindMy` |

系统按「已注册的 bundle ID + 路径」启动可执行文件 → TrollStore 安装后，桌面「查找」图标点开即本 App。
**代价**：原版「查找」App 可能无法再从桌面进入（iCloud 侧定位不受影响）。

---

## 目录结构

```
白米饭复刻/
├─ app/
│  ├─ project.yml                XcodeGen 工程描述
│  ├─ Sources/
│  │  ├─ main.mm                 入口（普通 / HUD 双角色分流）
│  │  ├─ App/                    主界面控制台
│  │  ├─ HUD/                    HUD 角色（M2）
│  │  ├─ Render/                 Metal / ImGui（M2）
│  │  ├─ Kernel/                 kfd / kfund（M3）
│  │  ├─ Read/                   mach_vm 读取后端（M4）
│  │  ├─ Game/                   偏移表 / 投影 / ESP（M4）
│  │  └─ Features/               清理 / 防封 / 游戏模式（M1）
│  ├─ Support/
│  │  ├─ Info.plist              伪装「查找」
│  │  └─ entitlements.plist      7 项权限
│  └─ Resources/                 图标 / 清理规则 / 字体
├─ docs/
│  ├─ 复刻总方案.md              ★ 总设计
│  ├─ kfd-集成调研.md            KFD 选型与硬约束
│  └─ imgui-集成调研.md          ImGui/Metal 集成
├─ scripts/make_icon.py          图标生成
└─ .github/workflows/build.yml   云构建
```

---

## 构建与安装

### 1. 推送触发云构建

```bash
cd 白米饭复刻
git init
git add -A
git commit -m "M0: 伪装壳 + 主界面控制台"
git branch -M main
git remote add origin https://github.com/xiaoping0902/<仓库名>.git
git push -u origin main
```

仓库建 GitHub 时**选 Public**（公开仓免费用 macOS 云机器）。

### 2. 取产物

GitHub 仓库页 → **Actions** → 等绿色 ✓ → 页面底部 **Artifacts** → 下载 `FindMy-unsigned-ipa.zip` → 解出 `FindMy-unsigned.ipa`。

### 3. 装机

把 IPA 传到 iPad → **TrollStore** 打开 → 安装。
装好后桌面出现**「查找」**图标，点开是本 App 的控制台。

### 4. 装机验收（按安全到危险排序）

**① 自检（安全）**
- [ ] 桌面「查找」图标点开 = 我方控制台
- [ ] `/var/Keychains`、`/var/mobile`、`/Applications` 均显示 **✓ 可见 N 项**（= entitlements 生效）
- [ ] 「运行身份」显示 `uid=... gid=... · iOS 16.6.1 · arm64e`

**② 悬浮窗（安全）**
- [ ] 点「启动悬浮窗」→ 浮出 ImGui 菜单（深色圆角卡片 + 三页签）
- [ ] 汉字正常、菜单控件可操作、标题拖动跟手、收球可恢复；菜单外能操作下层

**③ 能力探测（安全，不跑漏洞）**
- [ ] 「启动内核」页 → 底部「能力探测」→ 报告复制出来
- [ ] 关注：`task_get_special_port` 是否通 · **路 B 能否枚举进程**

**④ 启动内核（⚠️ 有风险，前三步都过了再做）**
- [ ] 会打 `RLIMIT_NOFILE` / `maxfilesperproc` / `kern.version`
- [ ] **失败后不要原地重试** —— 重启 App

①不通过 → entitlements 没生效，回查 `app/Support/entitlements.plist` 与 CI 里的 `ldid` 步骤。
③的完整判读标准见 [复刻版验证状态](docs/复刻版验证状态.md) §5。

---

## 关键技术约束（详见 docs/）

**KFD（Target = 16.6.1 / M2）**
- 16.6.1 上唯一可用 PUAF = `puaf_landa`（physpuppet 于 16.4、smith 于 16.5.1 已修）
- 必须 `kread_sem_open` + `kwrite_sem_open` 成对使用
- **上游 kfd 原样编入会立刻失败**（偏移表无 16.6.1/T8112）→ 需移植 kfund 运行时 patchfinder
- M1/M2 内核链接基址 = `0xFFFFFE0007004000`
- 必须单 TU include + 纯 C 桥接层（避免 `min/max` 宏污染 C++）

**ImGui（1.93 WIP）**
- 只编 5 个核心 cpp + `backends/imgui_impl_metal.mm`
- 动态字体体系：**不传 GlyphRanges、不调 Build()**
- 官方**没有** iOS 输入后端，触摸映射需自写
- master 分支**没有多视口**，HUD 只能画在单一 layer

---

## 许可与来源

- ImGui：MIT（`app/Sources/Render/imgui/LICENSE.txt`）
- kfd：MIT（`app/Sources/Kernel/kfd/LICENSE`）
- 本工程代码：自用
