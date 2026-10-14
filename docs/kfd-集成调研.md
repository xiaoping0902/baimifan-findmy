# kfd 集成调研报告（felix-pb/kfd）

- 调研日期：2026-10-14
- 目标设备：**iPad Pro M2（12.9"/11"，arm64e，机型 iPad14,3 / iPad14,4）· iPadOS 16.6.1（20G81）· TrollStore 安装**
- 用途：为「白米饭复刻」App 的 **KFD 内核链**（M3 里程碑）提供选型、API 与编译集成依据
- 本地代码：`app/Sources/Kernel/kfd/`（克隆自 `https://github.com/felix-pb/kfd` 的 `main` 分支，MIT 许可，已按要求删除 `.git`，无 commit 号可回溯）
- 校验哈希（sha256，用于日后核对源码版本）：

| 文件 | sha256（前 16 位） |
|---|---|
| `kfd/libkfd.h` | `f1ecdc47b3e45b7d` |
| `kfd/libkfd/info/dynamic_info.h` | `7dad0a0281d04fbe` |
| `kfd/libkfd/puaf/landa.h` | `8691e8ddd9f7fdaf` |
| `README.md` | `398bfcb8f9eb59db` |

> 全文用 **【已证】【推断】【未证】** 分层标注：
> **【已证】** = 有代码 / 一手文档 / 官方发布说明直接支撑（附出处）；
> **【推断】** = 由已证事实合理外推，或社区一手经验但未在本机复现；
> **【未证】** = 目前无可靠证据，需上机实测或需额外资料。

---

## 0. 结论速览（先看这里）

| # | 结论 | 标注 |
|---|---|---|
| 1 | 目标机（iPadOS 16.6.1 + M2）**唯一可用的 PUAF 方法是 `puaf_landa`**：physpuppet 在 iOS 16.4 被修复，smith 在 iOS 16.5.1 被修复；landa（CVE-2023-41974）直到 iOS 17.0 才被修复（16.7 RC 静默修复） | 【已证】README + writeups + Apple 安全公告 + theapplewiki |
| 2 | kread/kwrite **必须用 `kread_sem_open` + `kwrite_sem_open` 组合**：`kread_kqueue_workloop_ctl` 在 iOS 16.5+ 的偏移表里被标为 `false`，且 `krkw.h` 里有 `assert(kread_method != kread_kqueue_workloop_ctl)` 硬性拦截 | 【已证】`kfd/libkfd/krkw.h`、`info/dynamic_info.h` |
| 3 | **上游 kfd 原样烧进 16.6.1 会直接失败**：`info_init()` 用 `kern.version` 字符串前缀匹配偏移表，表里只有 iOS 16.5（iPhone 14 Pro Max / T8120）、iOS 16.6（iPhone 12 Pro / T8101）、macOS 13.4/13.5 四条，**没有任何 16.6.1 条目、也没有任何 T8112（M2）条目** → 落到 `assert_false("unsupported osversion")` → `sleep(30)` + `exit(1)` | 【已证】`kfd/libkfd/info.h` L93-103、`info/dynamic_info.h` |
| 4 | **M1/M2 的内核链接基址与 iPhone 不同**：`ARM64_LINK_ADDR` 上游硬编码 `0xfffffff007004000`，而 T8103(M1)/T8112(M2) 必须用 `0xFFFFFE0007004000`（社区已修复的 "M1/M2 kbase regression"） | 【已证】kfund `fun/kpf/patchfinder.m` L186-192；Serotonin 更新日志 |
| 5 | `T1SZ_BOOT` 对 T8112（M2）应取 **17**（上游默认值恰好就是 17，iPhone 12 Pro 在 16.6 上反而要改成 25） | 【已证】kfund `kfd/libkfd/info.h` L105-112（注释给出 reddit 出处） |
| 6 | 推荐落地路线：**移植 kfund（wh1te4ever）的运行时 patchfinder 方案**（明确声明覆盖 iOS/iPadOS 16.0-16.6.1，且被 Serotonin、Misaka 采用），而不是维护静态偏移表 | 【已证】kfund README；Misaka v8.2.1 发布说明；Serotonin 更新日志 |
| 7 | M2 iPad + 16.6.1 的 kfd 可用性有社区实证：Misaka v8.2.1 明确「iOS 16.0 - 16.6.1 M1/M2 iPad」；TrollStar 声明「works with M1 and M2 chip-equipped iPad Pros」；TrollInstallerX 的 arm64e 16.5.1-16.6.1（含 M2）走 kfd + kernelcache patchfind | 【已证】各家发布说明/README |
| 8 | 稳定性上最大的现实风险来自 **fd 上限、内存大小（16GB 机型社区反馈不稳）与失败后的 `exit(1)`**，而不是 landa 本身 | 【已证】Dopamine v2 发布说明；`kread_sem_open.h`；`common.h` L117-124 |

---

## 1. kfd 支持范围总表

### 1.1 PUAF 方法 × 系统版本（核心对照表）

| PUAF 方法 | 漏洞 | 修复版本 | 可用区间（iOS/iPadOS） | 沙盒可达性 | 备注 |
|---|---|---|---|---|---|
| `puaf_physpuppet` | CVE-2023-23536 | iOS 16.4 / macOS 13.3 | **≤ 16.3.x** | App Sandbox 可达；WebContent 不可达 | $52,500 赏金；作者实测 iOS 16.1 / macOS 13.0 |
| `puaf_smith` | CVE-2023-32434 | iOS 16.5.1 / macOS 13.4.1 | **≤ 16.5** | WebContent 可达（疑被在野利用） | KRKW 后需要专门清理（`smith_helper_cleanup()`），进程提前退出易 panic |
| `puaf_landa` | CVE-2023-41974 | **iOS 17.0**（16.7 RC 静默修复）/ macOS 14.0 | **≤ 16.6.1（含 16.6.1）** | App Sandbox 可达；WebContent 不可达 | $70,000 赏金；Dopamine 2 用它与 PPL bypass 组合覆盖 arm64e 15.0-16.6.1；**本项目的唯一选择** |

来源：【已证】`README.md` 与 `writeups/{physpuppet,smith,landa}.md`（本地代码）、theapplewiki `kfd (landa)` 条目、idownloadblog 2024-01-01 报道（landa 在 16.7 被修复）。

> 组合规则（代码级）：
> - `puaf_landa` 可配合任意 kread/kwrite 后端；
> - `kread_sem_open` **必须**配 `kwrite_sem_open`（`krkw.h` 中 `assert`）；
> - `kread_kqueue_workloop_ctl` 在 16.5+ 被表位 `false` 禁用。

### 1.2 版本 × 芯片可用性对照（面向 16.x）

| iOS/iPadOS 版本 | A9~A11 (arm64) | A12~A14 (arm64e) | A15 / A16 | M1 / M2 (arm64e) | 该版本可用 PUAF |
|---|---|---|---|---|---|
| 15.0 – 16.1.2 | 社区分支可用（不稳【推断】） | physpuppet / smith | physpuppet / smith | physpuppet / smith | physpuppet、smith |
| 16.2 – 16.3.x | 同上 | physpuppet / smith | physpuppet / smith | physpuppet / smith | physpuppet、smith |
| 16.4 – 16.5 | 同上 | smith | smith | smith | smith（A15/A16/M2 在 16.5.1 起另无 dmaFail，见注） |
| **16.5.1 – 16.6.1** | 同上 | **landa** | **landa** | **landa** | **仅 landa** |
| 16.7+ / 17.0 | — | 无（landa 已修） | 无 | 无 | 无 |

注：
- A15/A16/M2 在 16.5.1 上「不支持 Direct installation」指的是 **dmaFail PPL bypass 失效**（影响装 TrollStore 的直装方式），**不影响 kfd 本身**——kfd 仍在 App Sandbox 内可用。【已证】TrollInstallerX README；【推断】因此 kfd 在 16.5.1 的 M2 上同样可用（TrollInstallerX 的 indirect 方法就是 kfd）。
- arm64（A9-A11）不是上游的重点：上游只提供 arm64e 向的偏移表；社区分支（如 Lrdsnow 的 `arm64` 分支）支持 arm64，但作者原话是「kfd doesn't work well on arm64 atm」。【已证】Lrdsnow/kfd_offsets README
- A8（iPhone 6/6 Plus）**不支持**：4K 页大小不适配（Dopamine 说明）。【已证】
- WebContent 沙盒不可达这点对 TrollStore App 无影响（我们本来就是主 App 进程 / 自派生进程）。【推断】

### 1.3 上游偏移表实况（为什么 16.6.1「开箱不可用」）

`kfd/libkfd/info/dynamic_info.h` 中 `kern_versions[]` 只有 4 条【已证，本地代码】：

```c
const struct dynamic_info kern_versions[] = {
    // iOS 16.5 - iPhone 14 Pro Max   → xnu-8796.122.4~1/RELEASE_ARM64_T8120
    // iOS 16.6 - iPhone 12 Pro       → xnu-8796.142.1~1/RELEASE_ARM64_T8101
    //                                   ↑ 注释：T1SZ_BOOT must be changed to 25 instead of 17
    // macOS 13.4 - MacBook Air (M2)  → "todo"
    // macOS 13.5 - MacBook Air (M2)  → xnu-8796.141.3~6/RELEASE_ARM64_T8112
};
```

匹配方式是 **`kern.version` 前缀 memcmp**（`info.h` L93-100）：只要字符串不是以表内某条为前缀，就 `assert_false("unsupported osversion")`。
M2 iPad 的 `kern.version` 尾部是 **`RELEASE_ARM64_T8112`**（与 M2 MacBook Air 同 SoC 编号），表里唯一带 T8112 的是 macOS 条目且 `kern_version="todo"`，永远匹配不上。

M2 iPad 的真实内核串样例（iPad Pro 11" 4 代 / iPad14,4，iOS 16.4.1）【已证】Lrdsnow/kfd_offsets：

```
Darwin Kernel Version 22.4.0: Mon Mar 6 20:42:28 PST 2023; root:xnu-8796.102.5~1/RELEASE_ARM64_T8112
```

**16.6.1（20G81）的确切内核串：【未证】**。按规律应为 `Darwin Kernel Version 22.6.0: …; root:xnu-8796.142.x~x/RELEASE_ARM64_T8112`，但构建号/时间戳/`~x` 无法从公开资料确定。获取办法见 §4.4。

---

## 2. 目标机（iPad Pro M2 + iPadOS 16.6.1）推荐方案

### 2.1 推荐参数（直接可用的一组）

```c
u64 kfd = kopen(
    2048,               // puaf_pages：见下方说明
    puaf_landa,         // 【已证】16.6.1 上唯一可行的 PUAF
    kread_sem_open,     // 【已证】kqueue_workloop_ctl 被 assert 禁用
    kwrite_sem_open     // 【已证】必须与 kread_sem_open 成对
);
```

- `puaf_pages`：上游示例默认给到上限 **2048**（ContentView 默认选中 2048，`kopen` 断言区间 16–2048）。目标机是 8GB/16GB 内存的 iPad，社区普遍从 2048 起步、不稳再降（1024/512）。**最优值【未证】**，需上机扫。【已证：区间与默认值】
- landa 失败可在同一进程内**重试**（kfund 在 `kopen()` 里对 landa 做了 goto retry 的循环，来源注明 m1zole / dunkeyyfong）。【已证：kfund 代码】

### 2.2 为什么不能「直接编上游」

三个必须处理的问题（全部【已证】）：

| 问题 | 现象 | 依据 | 修改 |
|---|---|---|---|
| 偏移表无 16.6.1 / 无 T8112 条目 | `unsupported osversion` → sleep(30)+exit(1) | `info.h`、`dynamic_info.h` | 加表项 **或** 改用运行时 patchfinder |
| M1/M2 内核链接基址不同 | kslide 计算错误 → 后续 kread 全错/`Kernel data abort` | kfund `patchfinder.m` L186-192；Serotonin「Fixed M1/2 regression…kbase on these devices should be fixed」 | `ARM64_LINK_ADDR` 改 `0xFFFFFE0007004000` |
| `T1SZ_BOOT` 机型差异 | 指针 PAC 剥离错误（`UNSIGN_PTR`）；上游默认 17，iPhone 12 Pro@16.6 需 25 | 上游 `static_info.h` L22 + dynamic_info 注释；kfund 规则：T8120/T8103/T8112→17，其它→25 | T8112 保持 17（若要通用化则做成运行时变量） |

### 2.3 三条落地路线（按推荐度排序）

| 路线 | 做法 | 优点 | 成本/风险 | 证据 |
|---|---|---|---|---|
| **A. 移植 kfund 的运行时 patchfinder（推荐）** | 把 `wh1te4ever/kfund` 的 `fun/kpf/`（`patchfinder.{h,m}` + `libdimentio.{h,m}`）+ 改造过的 `libkfd`（动态 `t1sz_boot`/`arm64_link_addr`、patchfinder 回填 `proc__object_size` 与 kernelcache 地址、landa 重试）一并接入 | 明确覆盖 **16.0–16.6.1**；不再依赖机型偏移表；Serotonin / Misaka 都在用 | 需要把 .m/.c 引到工程；patchfinder 依赖**运行时能读到 kernelcache**（见 §5 第 7 条） | kfund README；Serotonin 更新日志「Added kfund kpf… effectively adds support for arm64 devices and fixes support for iPads」 |
| **B. 上游 + 手工偏移表** | 给 `dynamic_info.h` 增加 16.6.1/T8112 条目（`proc__*`、`task__map` 等），并修 `ARM64_LINK_ADDR` | 改动小、纯离线 | 需要一台 Mac 生成偏移（`c22dev/OffsetFinder` 或 `Lrdsnow/kfd_offsets` 的 `Global/dynamic_info.h`，后者 138KB 汇总表）；版本升级要重做 | Lrdsnow/kfd_offsets README（含「iPad offsets… none of these have worked sadly, need fix」的警告——**别照抄 iPad 现成偏移**） |
| **C. 运行时 patchfind kernelcache（TrollInstallerX 路线）** | 下载/内置本机 kernelcache，跑 Dopamine 系 kernel patchfinder（`libgrabkernel2` + opa334 patchfinder）拿 kbase 与静态地址 | 最「正统」、可跨版本 | 需要联网或把 kernelcache 打进 IPA（体积 +几十 MB）；实现量大 | TrollInstallerX README:「iOS 16.2 – 16.6.1 … require an internet connection … download the kernelcache and patchfind it」 |

> 对「白米饭复刻」的建议：**主路 A + 兜底 B**。M3 先按 A 集成并保留「内核设置」页的 puaf_pages/method 手选（与白米饭原版交互一致）；B 作为 A 的调试对照（先用 A 跑出的 kbase 反推偏移，再写回表）。

### 2.4 交叉验证过的社区实证（针对 M2 + 16.6.1）

| 来源 | 原文要点 | 对我们的意义 |
|---|---|---|
| Misaka v8.2.1 发布说明（straight-tamago） | 「Added support for iPadOS 16.0-16.6.1 on M1 and M2 chip-equipped iPads」「M1 and M2 iPads can now share the same IPA」「With the addition of KPF, All arm64/arm64e (15 - 16.6.1) devices are now supported」 | **M2 iPad 在 16.6.1 上用 kfd（landa+KPF）已被公开验证** |
| TrollStar（Little_34306）报道 | 「intended to support all iOS & iPadOS 16.0-16.6.1 devices, ranging from iPhone 8 to iPhone 14 Pro Max… It even works with M1 and M2 chip-equipped iPad Pros」 | 同上，第三方独立验证 |
| TrollInstallerX README | 16.5.1-16.6.1 (arm64e, 含 M2) 走 kfd 替换系统 App；16.2-16.6.1 需联网 patchfind | 官方路径 = kfd + 运行时 patchfind |
| kfund README | 「Experimental dynamic patchfinder is now working (patchfinder only works with landa/physpuppet)」「Supposed to be work: iOS/iPadOS 16.0-16.6.1」 | patchfinder 只配 landa/physpuppet（smith 不适用） |
| Dopamine v2 发布说明 | arm64e 支持到 16.5.1（kfd+landa）；「16GB memory devices aren't yet properly supported due to the KFD exploit not working well with high amounts of RAM」 | 16GB 版 iPad 有已知的 KFD 不稳问题 |

---

## 3. kfd 的 kread/kwrite API 清单

### 3.1 公共 API（全部实现在头文件里，`kfd/libkfd.h`）

| 函数 | 签名 | 语义/说明 |
|---|---|---|
| `kopen` | `u64 kopen(u64 puaf_pages, u64 puaf_method, u64 kread_method, u64 kwrite_method);` | 概念上「打开内核文件描述符」。成功返回不透明句柄（实为用户态指针）。**失败时：打印错误 → sleep(30) → exit(1)**。`puaf_pages` 断言区间 16–2048，方法值断言范围见下 |
| `kread` | `void kread(u64 kfd, u64 kaddr, void* uaddr, u64 size);` | 等价 `copyout()`：把内核地址 `kaddr` 的 `size` 字节读到用户缓冲 `uaddr` |
| `kwrite` | `void kwrite(u64 kfd, void* uaddr, u64 kaddr, u64 size);` | 等价 `copyin()`：把用户缓冲 `uaddr` 的 `size` 字节写到内核地址 `kaddr` |
| `kclose` | `void kclose(u64 kfd);` | 释放/清理（含 landa 的 PUAF 页、perf 的 dev 修补等）。**不调用直接退出进程，可能留下内核态脏状态**（见 §5） |

```c
enum puaf_method { puaf_physpuppet, puaf_smith, puaf_landa };     // 0 / 1 / 2
enum kread_method { kread_kqueue_workloop_ctl, kread_sem_open };  // 0 / 1
enum kwrite_method { kwrite_dup, kwrite_sem_open };               // 0 / 1
```

### 3.2 用法示例

C / Objective-C（推荐接法，见 §4.3 的桥接层）：

```c
#include "libkfd.h"

u64 g_kfd = 0;

int kfd_start(void)
{
    g_kfd = kopen(2048, puaf_landa, kread_sem_open, kwrite_sem_open);
    return g_kfd ? 0 : -1;   // 注意：kopen 失败会自己 sleep(30)+exit(1)，要拦截需改 assert 宏
}

// 读 4 字节（例：读 proc->p_pid）
u32 pid = 0;
kread(g_kfd, proc_addr + 0x60, &pid, sizeof(pid));

// 写回（例）
u32 new_pid = pid;
kwrite(g_kfd, &new_pid, proc_addr + 0x60, sizeof(new_pid));

void kfd_stop(void) { if (g_kfd) { kclose(g_kfd); g_kfd = 0; } }
```

Swift（上游示例 `kfd/ContentView.swift` 的写法，经 bridging header 暴露）：

```swift
let kfd = kopen(UInt64(puaf_pages), UInt64(puaf_method), UInt64(kread_method), UInt64(kwrite_method))
// 默认 UI 选择：puaf_pages=2048, puaf_method=2(landa), kread=1(sem_open), kwrite=1(sem_open)
kclose(kfd)
```

macOS 命令行示例（`macos_kfd.c`，与本项目无关但可作最小模板）：

```c
u64 kfd = kopen(2048, puaf_landa, kread_sem_open, kwrite_sem_open);
kclose(kfd);
```

### 3.3 库内部可用但「半公开」的设施（同一 TU 内可用）

| 名称 | 位置 | 用途 |
|---|---|---|
| `struct kfd* kfd` 的 `info.kaddr.current_proc` / `kernel_proc` / `kernel_task` / `kernel_map` / `kernel_pmap` | `libkfd.h` + `info.h` | `info_run()` 之后即可直接拿当前进程与内核对象的 kernel VA（白米饭「启动内核 → 提权 → 枚举 task」的起点） |
| `dynamic_kget/dynamic_kset`、`static_kget/static_kset` 宏 | `info.h` | 按偏移表/结构体偏移读写字段的语法糖 |
| `UNSIGN_PTR(p)` | `static_info.h` | 剥离 PAC（依赖 `T1SZ_BOOT`） |
| `kread_sem_open_kread_u32()` | `krkw/kread/kread_sem_open.h` | 保证不下溢到上一页的读法（避免页边界 `Kernel data abort`） |
| `kfd->perf.*`（perfmon 直读/直写「更好的 KRKW」） | `perf.h` | 依赖 kernelcache 静态地址；**16.6.1 无表项 → 需要 `perf_supported=false` 或自行 patchfind**，否则 `perf_init()` 直接跳过【已证：`perf.h` L69/L92】 |

### 3.4 kread/kwrite 的能力边界（重要）

- `kwrite` **不能写「0」、也不能把已有值改成 0**——`kwrite_sem_open` 底层（`kwrite_dup` 路径）靠文件描述符/对象字段做写入，值 0 不可表达；上游 writeup 明确写了这一点并提示用变通写法。【已证】`writeups/exploiting-puafs.md` L189-192
- `kread` 在页边界处可能连带读到上一页 → 用 `kread_sem_open_kread_u32()` 规避。【已证】同上 L182-188
- 两个后端都建立在「PUAF 页被喷入 `psemnode`/`fileproc` 对象」之上，**并发调用不安全**（喷对象/搜索/释放是有状态的）。建议全局串行 + 单线程。【推断，基于实现结构】

---

## 4. 编译集成清单

### 4.1 需要编入的文件（全部是**头文件实现**，无需 .c/.m 源文件）

```
app/Sources/Kernel/kfd/kfd/
├── libkfd.h                      ← 唯一入口（含 CONFIG_* 开关、公共 API、kfd_init/kopen）
└── libkfd/
    ├── common.h                  ← 基础类型/断言/打印宏、pages()、timer
    ├── info.h                    ← kern.version 匹配、info_run（拿 current_proc 等）
    │   ├── info/dynamic_info.h   ← 偏移表 kern_versions[] ← 16.6.1 改造点 ①
    │   └── info/static_info.h    ← 结构体定义、T1SZ_BOOT、ARM64_LINK_ADDR ← 改造点 ②③
    ├── puaf.h + puaf/{landa,physpuppet,smith}.h   ← 三种 PUAF 实现（landa=我们要用的）
    ├── krkw.h + krkw/kread/{kread_kqueue_workloop_ctl,kread_sem_open}.h
    │            krkw/kwrite/{kwrite_dup,kwrite_sem_open}.h
    └── perf.h                    ← 可选（需要 kernelcache 静态地址；16.6.1 建议关）
```

**不需要**编入：`kfd.xcodeproj/`（上游示例工程）、`kfd/ContentView.swift`、`kfd/kfdApp.swift`、`kfd/Assets.xcassets`、`writeups/`（参考文档）。建议在 XcodeGen 的 `excludes` 里排掉 `kfd/kfd.xcodeproj` 与 `kfd/writeups`，否则工程文件会被当资源扫进去。

### 4.2 编译规则（踩过就知道的硬约束）

1. **必须在且仅在一个编译单元里 `#include "libkfd.h"`**。头文件里的函数（`kopen/info_init/puaf_run/…`）与 `kern_versions[]` 是**无 `static` 的普通定义**，被两个 TU 包含 = 重复符号链接错误（C/C++ 都一样）。【已证：源码结构】
2. **不要把它包含进普通 .mm 业务代码**：`common.h` 里 `#define min(a,b)` / `#define max(a,b)` 会污染 C++ 标准库（与 `std::min/std::max`、STL 头冲突）。做法：**加一层纯 C 桥接文件** `Kernel/kfd_bridge.c`（只 include libkfd.h）+ 干净头文件 `kfd_bridge.h`（只有 C 原型），业务 .mm 只 include 后者。
3. 头文件搜索路径要指向 `app/Sources/Kernel/kfd/kfd`（因为 `libkfd.h` 内部按 `"libkfd/common.h"` 相对包含）。
4. `TARGET_MACOS` **不要定义**（只有 `macos_kfd.c` 用）；不定义即 iOS 路径。
5. 语言/优化：C（clang 默认 gnu17 即可）；上游 macOS Makefile 用 `clang -O3 -Wno-deprecated-declarations`，iOS 侧建议同样带 `-Wno-deprecated-declarations`（`sem_open`/`syscall` 等旧 API 会告警）。
6. `CONFIG_*` 开关位于 `libkfd.h` 顶部：
   - `CONFIG_ASSERT 1`：断言失败 = `print("... sleep(30) before exit(1) ...")` → `sleep(30)` → `exit(1)`。**在 App 里这会表现成「卡 30 秒后闪退」**，建议改造：①保持断言但在桥接层先探测环境（机型/版本）避免误入；②或把 `assert` 宏改成「置错误码 + 返回」的版本（需要动 `common.h`）。
   - `CONFIG_PRINT 1`：海量 `print_x64` 日志（含 kbase/kslide/proc 地址）。Release 构建建议改 0（`NSLog` 冲突与性能都要考虑）。
   - `CONFIG_TIMER 1`：各阶段耗时打印，调试期留、发布可关。
7. 上游示例的 `IPHONEOS_DEPLOYMENT_TARGET = 16.4`、`CLANG_ENABLE_OBJC_ARC = YES`、`SWIFT_OBJC_BRIDGING_HEADER = kfd/kfd-Bridging-Header.h`（内容就一句 `#include "libkfd.h"`）可作为对照。

### 4.3 依赖的系统 framework / 权限

| 项 | 结论 | 依据 |
|---|---|---|
| 系统 framework | **无额外依赖**。只用 libSystem/Mach/BSD：`mach/mach.h`、`sys/{ioctl,mmap,syscall,sysctl}.h`、`semaphore.h`、`pthread.h` 等；**全仓无 IOKit 引用** | 【已证】`common.h` include 列表 + 全仓 grep 无 IOKit/framework |
| entitlements | **kfd 本体不需要任何特殊权限**：漏洞从 App Sandbox 内可达（WebContent 不可达）。上游示例 App 自带的 `kfd.entitlements` 只是 `com.apple.security.app-sandbox = true` + `files.user-selected.read-only`，属于示例工程，与利用无关 | 【已证】`kfd/kfd.entitlements`；README |
| 与本项目的配合 | 我们的 App 是 TrollStore 安装、带原版 7 项 entitlements（`no-sandbox` / `task_for_pid-allow` 等）。这些**不影响** kfd 工作；反过来 kfd 也不依赖它们。HUD 进程内跑 kfd【推断可行，因为 kfd 只需 App Sandbox；建议主进程跑，失败更好诊断】 | 【推断】 |
| 架构 | App 编 **arm64** 即可（跑在 arm64e 内核上）；不需要 arm64e 编译；但**必须有真机 arm64 slice**（模拟器不行——Mach 接口行为不同） | 【推断，社区通例】 |

### 4.4 上机前后必做的三件事（拿 16.6.1 的真实参数）

1. **读真实 `kern.version`**：上游 `info_init()` 在比对失败**之前**会 `print_string(kern_version)`（`info.h` L88-96）——所以把 CONFIG_PRINT 打开跑一次，日志里就能看到目标机的完整内核串，用它做偏移表条目的 `kern_version` 前缀。【已证：代码顺序】
2. **拿真实 kbase/kslide**：优先用 kfund 的方式——从内核 `task` 的 tte 向前扫描页找 `0x100000cfeedfacf`（MH_MAGIC_64）确定 kbase，再 `kslide = kbase - ARM64_LINK_ADDR(0xFFFFFE0007004000)`。【已证：kfund `krkw.h` L186-210】
3. **验证 `T1SZ_BOOT`/指针剥离**：先只做 kread 冒烟（读 `current_proc` 并校验 `p_pid` 等于自身 pid），再动 kwrite。`UNSIGN_PTR` 剥错会让所有指针变野指针 → `Kernel data abort`。【推断：由宏语义决定】

### 4.5 云构建（GitHub Actions）注意点

- kfd 是 header-only + 纯 C，**对 CI 无特殊要求**；macOS runner 上 `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` 出未签名 IPA 即可。
- 别把 `.mm` 桥接写成 C++ 编译（`.mm` 扩展名会按 ObjC++ 处理）：文件名用 `.c`（C）或 `.m`（ObjC），避免 `min/max` 宏与 C++ 冲突，也避免 const 全局在 C++ 下变外部链接引发重复符号。【推断：语言规则】
- 若选路线 A（kfund patchfinder），注意它需要**读 kernelcache**：要么联网下载（TrollInstallerX 模式），要么把目标机的 `kernelcache` 放进 IPA 资源里并在代码里指向该路径。CI 侧只需保证资源被打进 bundle。

---

## 5. 已知坑与稳定性注意事项

| # | 坑 | 现象 | 原因 | 对策 | 标注 |
|---|---|---|---|---|---|
| 1 | 上游不支持 16.6.1 | 日志 `unsupported osversion` → 卡 30 秒 → 进程退出 | `kern.version` 前缀表里没有 16.6.1 条目 | 走 §2.3 路线 A/B | 【已证】代码 |
| 2 | M1/M2 内核链接基址不同 | kslide 错 → 全部 kread 失败或 `Kernel data abort` panic | `ARM64_LINK_ADDR` 上游是 iPhone 值 | T8103/T8112 用 `0xFFFFFE0007004000` | 【已证】kfund + Serotonin |
| 3 | `T1SZ_BOOT` 机型差异 | 指针剥离错误（同 2 的现象） | 17 vs 25 随机型/构建而变 | T8112→17；通用化则设成运行时变量 | 【已证】kfund；【未证】16.6.1 上是否另有变化（上机验证） |
| 4 | `kqueue_workloop_ctl` 已废 | 直接 assert 拦下 | 16.3+ 内核封堵 | 用 `sem_open` 组合 | 【已证】代码 |
| 5 | fd 上限 | 卡在 `krkw_helper_run_allocate` / `sem_open` 返回失败 → assert | kread 后端要开 `maxfilesperproc-100` 个 fd；macOS 上默认不够 | 上游 `make s` 提 `kern.maxfilesperproc`；iOS 上先确认 `kern.maxfilesperproc` 与进程 rlimit；释放后再重试 | 【已证】READM + `kread_sem_open.h` |
| 6 | 失败即 `sleep(30)+exit(1)` | App 像「卡死后闪退」，用户以为崩了 | `common.h` 的 assert 宏 | 桥接层做机型/版本预检；或改 assert 宏为错误返回；landa 支持进程内重试 | 【已证】代码 |
| 7 | `Kernel data abort` panic | 设备重启 | 偏移/基址错，或 kread 跨到未映射页 | 偏移必须匹配机型版本；kread 用 u32 变体避页边界；**不要靠猜偏移** | 【已证】writeup |
| 8 | `page still has mappings` panic | 设备重启 | PUAF 页在写回时仍被映射（清理路径） | 按上游流程正确 `kclose()`；出错时优先整机重启而不是继续尝试 | 【已证】writeup |
| 9 | `perfmon: unpaired release` panic | 退出 App 后 panic | 用了 perf（更好的 KRKW）却没走 `kclose()` 清理 | 要么别启用 perf，要么保证 `kclose()`；`perf_free()` 会还原 `si_rdev/si_opencount` | 【已证】writeup + `perf.h` |
| 10 | 退出后 `open("/dev/aes_0")` 报 EMFILE | 第二次启动 kfd 直接失败 | 上一次没 `kclose()`，内核对象没归还 | 永远配 `kclose()`；重试前先重启进程 | 【已证】writeup |
| 11 | 16GB 内存机型不稳 | 成功率低/偶发 panic | 社区结论：KFD 对高内存设备不友好 | 8GB 机型优先测试；16GB 上降低 puaf_pages 多试 | 【已证】Dopamine 发布说明 |
| 12 | 「Exploiting kernel」卡死 | 进度条卡住 | kfd 常见抽风 | **重启设备再试**（TrollInstallerX FAQ 原文建议） | 【已证】TrollInstallerX README |
| 13 | kwrite 写 0 不生效 | 字段写不进去 | 后端表达能力限制 | 用非零值/等价改法（改指针而非置 0 等） | 【已证】writeup |
| 14 | 多次使用后状态劣化 | 偶发 panic / 功能失效 | kfd 会污染内核对象（社区多次警告，例：ID-Changer 作者称「kfd likes to corrupt…may kernel panic after using it multiple times」） | 内核链只做必要 patch，减少 kwrite 次数；崩溃后重启 | 【已证】社区一手警告 |
| 15 | 线程安全 | 随机失败/panic | kread/kwrite 后端有状态（对象喷/搜/释放） | 全局串行化，禁止并发调用 | 【推断】 |
| 16 | 与 C++ 工程冲突 | 编译报 `min/max` 重定义或重复符号 | `common.h` 的宏 + 头文件里的非 static 定义 | 单 TU + 纯 C 桥接层（§4.2） | 【已证】源码 |
| 17 | 模拟器编译/运行 | 行为异常 | kfd 只面向真机内核 | CI 只出真机包，测试用真机 | 【推断】 |

---

## 6. 参考来源清单

**一手（代码/官方仓库）**
1. felix-pb/kfd —— README、`writeups/physpuppet.md`、`smith.md`、`landa.md`、`exploiting-puafs.md`（本地已克隆：`app/Sources/Kernel/kfd/`）
2. felix-pb/kfd `kern-version` 分支的 `dynamic_info.h`（与 main 一致）
3. wh1te4ever/kfund —— README（支持 16.0-16.6.1）、`kfd/libkfd/info.h`（`t1sz_boot` 规则）、`fun/kpf/patchfinder.m`（`get_vm_kernel_link_addr`、kbase 扫描）、`kfd/libkfd/krkw.h`（kbase patchfind + landa 重试）
4. alfiecg24/TrollInstallerX —— README（arm64e 16.5.1-16.6.1 走 kfd；16.2+ 需联网 patchfind kernelcache；FAQ「Exploiting kernel」）
5. straight-tamago/misaka —— Releases（v8.2.x：「iOS 16.0 - 16.6.1 M1/M2 iPad」）
6. Lrdsnow/kfd_offsets —— README（t1sz_boot 说明、iPad 偏移「need fix」警告）；`DeviceSpecific/iPad14,4/iOS_16.4.1/dynamic_info.h`（M2 iPad 的真实 kern.version：T8112）
7. apple-oss-distributions/xnu —— `osfmk/arm64/proc_reg.h`（T1SZ_BOOT 条件编译：16K 页 + `__ARM64_PMAP_SUBPAGE_L1__` → 25，否则 17）
8. theapplewiki.com —— `Kernel` 页（各版本 Darwin 串）、`kfd (landa)` 页（CVE-2023-41974：iOS ≤16.6.1 受影响，16.7 RC 静默修复，iOS 17.0 正式修复）
9. appledb.dev —— iPad14,3/14,4 = M2、arm64e 确认

**二手（报道/经验）**
10. idownloadblog：Dopamine v2（kfd+landa、16GB 机型问题）、landa 支持 iOS 16.x 全线（2024-01-01）、TrollStar（M1/M2 iPad Pro 可用）、Misaka v8.2.1（M1/M2 iPad 统一 IPA）
11. Serotonin Releases（kfund kpf 修 M1/M2 kbase 回归；arm64/arm64e + iPad 修复）
12. ios.cfw.guide（TrollInstallerX 安装教程：16.6-16.6.1 arm64e 需通过 persistence helper 二段安装）
13. linux.do 等中文社区实战帖（TrollInstallerX 装机流程与网络要求）

---

## 7. 待办（M3 之前建议最小验证集）

- [ ] 真机 `sysctl kern.version` 采样（拿到 16.6.1/T8112 的精确内核串）→ 回填/校验偏移表
- [ ] 用 kfund 路线做 kread 冒烟：读 `current_proc`，校验 `p_pid == getpid()`
- [ ] landa 成功率的 20 次连测（不同 `puaf_pages`：512/1024/2048）→ 定默认值
- [ ] 确认 16.6.1 上 `perf` 是否启用（不启用则 `perf_supported = false`，功能不受影响）
- [ ] 桥接层与「内核设置」页联动：方法手选（landa 固定）+ pages 可选 + 失败重试 + 友好错误提示（替代 exit(1)）
