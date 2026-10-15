# 白米饭复刻 · FindMy

一个 iOS 工具 App：**伪装成系统「查找」**，带主界面控制台、悬浮 HUD（C++ ImGui/Metal）、内核读取链与系统清理功能。
本轮实际验证设备：**iPad8,11 / A12Z · iPadOS 16.6.1 · TrollStore**。源码在 Windows 上维护，Apple SDK 编译与 simulator 回归在 GitHub Actions macOS 执行。

> 本工程为**独立重写**，参考对象是 `白米饭无验证.ipa` 的静态逆向分析结论（见 `docs/复刻总方案.md` §3）。
> 不含任何授权校验、联网上报或设备指纹采集。

---

## 当前进度

最新 HUD 修复位于 `fix/hud-reliability`，已生成 **M5.69 / `3859ba1-r69`** 安装包。启动、输入、布局、渲染和停止流程按生产类回归及真机证据分别验收；历史构建成功不能代替设备触摸和游戏数据验证。

六套生产回归已有通过记录，Release arm64 和 IPA 检查通过；其中完整 run 的菜单截图曾超时，修正测试时序后菜单单独通过。当前 iPad 仍为 M5.67，新版物理安装、穿透、流畅性、退出及重启验收待完成，详见本轮报告。

- [本轮 HUD 稳定性修复与验收](docs/HUD稳定性修复与验收-2026-10-16.md)：现场旧 PID 误认、根因、修复、实际测试及安装记录。
- [功能差距审查](docs/功能差距审查-2026-10-16.md)：真实名称、骨骼、物资分类、偏移、UE4 衔接及 root 业务等剩余缺口。
- 本机安装包：`dist/hud-reliability-M5.69/FindMy-M5.69-HUD.ipa`，通过 TrollStore 覆盖安装；同目录保存版本和 SHA256 核验记录。

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

### 待验证与待完成

- ⏳ **本轮修复真机验收** —— iPad 已连接；新版本交互、穿透、退出与重启需逐项确认。
- ⛔ **游戏偏移校准** —— 需要**目标游戏本体**（进程名/模块名/对象链/骨骼拓扑都是游戏的逆向结果）

### 本地自检

```bash
python -X utf8 scripts/preflight.py # 当前 154 项通过，Windows 使用 UTF-8 输出
python scripts/verify_ipa.py dist/FindMy-unsigned.ipa   # IPA 验货（含 entitlements 逐条核对）
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
- [ ] 汉字正常、拖动跟手、菜单外能点到底层（穿透生效）

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
