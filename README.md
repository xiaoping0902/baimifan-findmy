# 白米饭复刻 · FindMy

一个 iOS 工具 App：**伪装成系统「查找」**，带主界面控制台、悬浮 HUD（C++ ImGui/Metal）、内核读取链与系统清理功能。
目标机：**iPad Pro M2 · iPadOS 16.6.1 · TrollStore**。构建全程在 Windows 上完成（GitHub Actions 云编译）。

> 本工程为**独立重写**，参考对象是 `白米饭无验证.ipa` 的静态逆向分析结论（见 `docs/复刻总方案.md` §3）。
> 不含任何授权校验、联网上报或设备指纹采集。

---

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** | 伪装壳 + 云构建管道 + entitlements 自检 | 🚧 代码就绪，待云构建验证 |
| M1 | 主界面控制台 + 清理系统残留 + 清理 Key + 防封 + 游戏模式 | ⬜ |
| M2 | `-hud` 自派生 + 双窗口托管 + ImGui 三页菜单 | ⬜ |
| M3 | KFD 内核链（kfund patchfinder + landa + task 枚举） | ⬜ |
| M4 | 读取后端 + 投影 + ESP 绘制 | ⬜ |

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

### 4. M0 验收标准

- [ ] 桌面「查找」图标点开 = 我方控制台界面
- [ ] 自检页里 `/var/Keychains`、`/var/mobile`、`/Applications` 均显示 **✓ 可见 N 项**（= entitlements 生效）
- [ ] 「运行身份」显示 `uid=... gid=... · iOS 16.6.1 · arm64e`

任一项不通过 → 说明 entitlements 没生效，需回查 `app/Support/entitlements.plist` 与 CI 里的 `ldid` 步骤。

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
