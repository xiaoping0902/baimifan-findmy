# kfd 移植清单（KFD 内核漏洞利用链 · M3 里程碑）

- 生成日期：2026-10-14
- 目标机：**iPad Pro M2（arm64e，T8112）/ iPadOS 16.6.1（20G81）/ TrollStore**
- 上游来源：`wh1te4ever/kfund`（`%TEMP%\kfund\kfund-main`），MIT，见 `app/Sources/Kernel/kfd/LICENSE`
- 前置报告：`docs/kfd-集成调研.md`（329 行，本文承接其 §2.3 路线 A）
- 结论一句话：**移植 kfund，落实为 20 个被编译的文件 + 4 个新增桥接文件 + 5 处最小 patch**；
  上游 felix-pb 那版静态偏移表对应的 `kfd/` 整体已被换掉，原件存于 `docs/_archive_kfd_upstream/kfd/`。

> 全文沿用【已证】【推断】【未证】分层。每条结论都注明了「依据：哪个文件哪一行」。

---

## 0. 结论速览

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | `libkfd.h` 重复符号 | 上游 kfund **只有 1 个编译单元** include 它：`fun/krw.m`。Swift 桥接头（`kfd-Bridging-Header.h`）**不含** `libkfd.h` | 【已证】见 §1 |
| 2 | `fun/krw.m` 会不会和桥接层撞车 | **会**。所以本工程**不编 `fun/` 目录**，把它唯一被用到的函数下放到桥接层 | 【已证】+【推断】见 §2 |
| 3 | patchfinder 要哪一层 API | 只要 **libkfd 层**的 `kread()` 一个函数。`libdimentio.m` 全文只有 1 个外部 KRW 调用点（L267 `early_kreadbuf`） | 【已证】见 §2.2 |
| 4 | 依赖闭包 | **20 个文件**（15 个 `libkfd/` 系 + 4 个 `fun/kpf/` + LICENSE）。**不需要整个 `fun/`** | 【已证】见 §2.4 |
| 5 | `compression.h` | **真用到**（`libdimentio.m` L17 包含、L253 `compression_decode_buffer`）。但 `-lcompression` 是否必需存疑 | 【已证】+【未证】见 §2.3 / §5.1 |
| 6 | `libdimentio.m` 要不要解 kernelcache | **不读磁盘**。`set_libdimentio_kernpath()` 从未被调用 → `kernel_path == NULL` → 走 `pfinder_init_kernel()` 纯内存 patchfind | 【已证】见 §2.2 |
| 7 | IOKit | **不需要**。`patchfinder.h` 里那堆 IOKit 原型**零调用点**（连 `IORegistryEntryFromPath` 都没人调） | 【已证】见 §2.3 |
| 8 | `exit(1)` 改造 | 4 处最小 patch，把断言换成 `longjmp` 回 `mf_kopen()`，失败变「返回错误码 + 错误字符串」 | 见 §6 |
| 8b | `patchfinder.m` 的 `#import "krw.h"` | **必须删**（本工程不编 `fun/`，该头不存在）。逐行核实该文件**零 krw 层调用**，属冗余依赖 → 第 5 处 patch | 【已证】见 §7.5 |
| 9 | 编译设置泄漏 | `ONLY_ACTIVE_ARCH=YES` 会让 Release 只出 x86_64 → 真机装不上（**与 kfd 无关，但会挡住这次交付**） | 【推断】见 §8.4 |
| 10 | `perf` 必须开 | kfund 的表把 iOS 16.x 的 `perf_supported` 设成 `true`，`kernel_slide` 由 perf 算出，**必须让 patchfinder 成功回填 9 个偏移** | 【已证】见 §9.1 |

---

## 0.1 ⚠️ 落地时的重要发现：下游消费者早已就绪

`app/Sources/Kernel/` 下本来就有两个文件（不在本次任务描述里，是复核时才发现的）：

| 文件 | 大小 | 说明 |
|---|---|---|
| `MFKernel.h` | 3389 B | ObjC 内核会话门面（`MFKernel` 单例 + `MFProcessInfo`） |
| `MFKernel.mm` | 14806 B | 实现；**L5 就是 `#import "MFKernelBridge.h"`** |

它对桥接层的全部调用（grep 实证，11 处）：

```
L69   mf_is_open()
L103  mf_kernel_version()
L111  mf_kopen(pages, 2 /*landa*/, 1 /*sem_open*/, 1 /*sem_open*/)
L119  mf_last_error()
L125  mf_get_kbase()
L126  mf_get_kslide()
L142  mf_kclose()
L237  mf_kernel_version()
L239  mf_is_open()
L388  mf_kread(kaddr, out, size) == 0
L393  mf_kwrite((void*)in, kaddr, size) == 0
```

**⇒ 与 `MFKernelBridge.h` 的声明逐个签名一致，零改动接入。**
（`mf_kopen` 的实参类型：`pages` 是 `uint64_t`，其余是 `int` 字面量 ✅）

三点结论：

1. **它是业务侧的唯一消费者**，且它已经遵守了「只 include 干净头、不碰 libkfd.h」的纪律。
   ⇒ 本桥接层的 ABI/接口不是我们凭空设计的，是被既有代码**倒逼出来的规格**，务必保持稳定。
2. `MFKernel.mm` 位于 `Sources/Kernel/`，**会被 `project.yml` 的 `Sources` 通配自动编入**
   （`Kernel/` 下现在只有 `kfd/vendor/**` 在 excludes 里）。
   ⇒ 它不在本次「逐文件精确加入」清单里，但**必须能编过**，否则 M3 直接挂。
3. 它 L101 已经在**后台队列**里跑 `mf_kopen`（`dispatch_async` + `QOS_CLASS_USER_INITIATED`）
   —— 正好对上 §9.6「landa 无限重试 / patchfinder 耗时长」的建议：
   **不要阻塞主线程**。但它目前**没有超时兜底**，见 §10 待办。

> 另外注意：`MFKernel.mm` L111-L114 传的是 `pages = 2` 位置上的 `uint64_t`，
> 而 `mf_kopen` 的第一个参数正是 `uint64_t puaf_pages` —— 名字叫 `pages` 但传的其实是
> **页数**（`mf_kopen` 会把 16..2048 之外的值判为非法，返回 -3）。
> 【推断】调用方语义正确，但若 UI 传进来的是字节数就会落在 -3。

---

## 1. 问题 1 的权威答案：kfund 实际编了哪些文件

依据：`%TEMP%\kfund\kfund-main\kfd.xcodeproj\project.pbxproj` 的 `PBXSourcesBuildPhase`
（`/* Begin PBXSourcesBuildPhase section */`，L344-367）。

### 1.1 `PBXSourcesBuildPhase` 实际清单（16 个编译单元）

| 类别 | 文件（pbxproj 里的路径） | 归属目录 |
|---|---|---|
| libkfd | **（无！）** | `kfd/libkfd/**` 全是 header-only，一个 .c/.m 都没有 |
| kpf | `patchfinder.m`（L361）、`libdimentio.m`（L363） | `kfd/fun/kpf/` |
| KRW 层 | `krw.m`（L362） | `kfd/fun/` |
| fun 其他 | `fun.m`(L350)、`offsets.m`(L354)、`proc.c`(L348)、`vnode.m`(L357)、`cs_blobs.m`(L352)、`utils.m`(L358)、`helpers.m`(L351)、`thanks_opa334dev_htrowii.m`(L356) | `kfd/fun/**` |
| mdc | `grant_full_disk_access.m`(L359) | `kfd/fun/mdc/` |
| mdc | `vm_unaligned_copy_switch_race.c`(L360) | `kfd/fun/mdc/` |
| ppl | `pplrw.m`(L355)、`GPU_CoreSight.m`(L349) | `kfd/fun/ppl/` |
| Swift | `kfdApp.swift`(L364)、`ContentView.swift`(L353) | `kfd/` |

`libkfd.h` 出现在 `PBXFileReference`（L43）但**不在** `PBXBuildFile`（L10-29）里 —— 它就只是个被引用、不参与编译的头文件。

### 1.2 `libkfd.h` 到底被谁 include？—— 全树 grep 结果

对 `%TEMP%\kfund\kfund-main` 全树搜 `#include`：

| 文件 | 行 | 内容 |
|---|---|---|
| `kfd\kfd-Bridging-Header.h` | L5-L7 | `fun/fun.h` / `fun/krw.h` / `fun/kpf/patchfinder.h` —— **没有 `libkfd.h`** |
| `kfd\fun\krw.m` | L9 | **`#include "libkfd.h"`** ← 全树唯一 |
| 其余所有 `.m/.c/.h` | — | 均不包含 |

**结论【已证】**：kfund 避免重复符号的办法不是宏开关，也不是「没同时编」，而是
**`libkfd.h` 只被 `fun/krw.m` 一个 TU 包含**，其他所有文件只通过 `fun/krw.h` 声明的
`do_kopen/do_kread/do_kwrite/kread32/...` 间接访问 libkfd。

> 这跟调研报告 §4.2 第 1 条的判断一致：「必须在且仅在一个编译单元里 include `libkfd.h`」。
> 现在有了上游自己的工程配置作为旁证。

### 1.3 由此推出的本工程硬约束

- `MFKernelBridge.c` = **全工程唯一** include `libkfd.h` 的 TU。
- 因为本工程**不编 `fun/krw.m`**（理由见 §2.1），所以还必须保证**没有任何其他文件**去 include 它。
- `libkfd/info/dynamic_info.h` 里 `struct dynamic_info kern_versions[] = {...}`（L34）同样是
  无 `static` 的外部定义，**共振约束同样适用**。

---

## 2. 问题 2：`run_kfd_patchfinder` 的最小依赖闭包

### 2.1 先解决碰撞：`fun/krw.m` 与桥接层必冲突

事实链：

1. `fun/krw.m` **L9** `#include "libkfd.h"`
2. `libkfd.h` 是 header-only：`kfd_init`(L148)、`kfd_free`(L158)、**`kopen`(L167)**、
   **`kread`(L207)**、**`kwrite`(L212)**、**`kclose`(L217)** —— 全是无 `static` 的普通定义
3. `MFKernelBridge.c` 也必须 include `libkfd.h`（要用 `kopen/kread/kwrite/kclose`）
4. ⇒ 两个 TU 都产出 `_kopen/_kread/_kwrite/_kclose` → **链接期 duplicate symbol**

三个可选解与选择：

| 方案 | 做法 | 评价 |
|---|---|---|
| A | 桥接层不 include，改 include `fun/krw.h` 只用 `do_*` | ❌ 那样桥接层就得把整个 `fun/`（18 个 .m/.c）拖进来 |
| B | 给 libkfd 的函数加 `static` | ❌ 改动量大，且 `fun/` 里其他文件跨 TU 引用它们就断 |
| **C（采用）** | **不编 `fun/krw.m`，把它唯一被 patchfinder 用到的那个函数下放到桥接层** | ✅ 见 §2.2 |

### 2.2 逐行核实：`patchfinder.m` / `libdimentio.m` 调的是哪一层

#### `patchfinder.m`（192 行，全文读过）

| 行 | 内容 | 依赖层 |
|---|---|---|
| L11-L13 | `#import "patchfinder.h"` / `#import "libdimentio.h"` / **`#import "krw.h"`** | 但见下 |
| L26-L37 | `getBootManifestHash()` —— 只用 `statfs` + `NSString` | 系统 |
| L39-L43 | `get_kernel_path()` —— 只用 `NSString` 拼路径（**结果没被任何地方用**） | 系统 |
| L45-L47 | `removeIfExist()` —— `access`/`remove`（**无调用点**） | 系统 |
| **L49-L113** | **`run_kfd_patchfinder()`** ← 核心 | — |
| L52-L53 | `get_vm_kernel_link_addr()`；`kslide = kbase - vm_kernel_link_addr` | 同文件 L186 |
| L54-L55 | `set_libdimentio_kbase()` / `set_libdimentio_kfd()` | `libdimentio.m` |
| L57-L58 | `pfinder_init(&pfinder)` | `libdimentio.m` |
| L63-L106 | 9 次 `pfinder_xxx(pfinder)` + 回填 `off_*` | `libdimentio.m` |
| L108 | `pfinder_term(&pfinder)` | `libdimentio.m` |
| L110 | `save_kfd_offsets()` | 同文件 L157（写 Documents 下的 plist） |
| L115-L121 | `get_kernversion()` —— `sysctlbyname("kern.version")` + `strdup` | 系统 |
| L123-L155 | `import_kfd_offsets()` —— 读 plist | 系统 |
| L157-L184 | `save_kfd_offsets()` —— 写 plist（用 `NSDictionary`） | 系统 |
| L186-L192 | `get_vm_kernel_link_addr()` —— `strstr` 判 T8103/T8112 | 系统 |

**关键发现**：`patchfinder.m` 虽然 L13 `#import "krw.h"`，但**全文没有任何一个来自 krw 层的函数被调用**。
`run_kfd_patchfinder` 用到的 `kread`-系能力全部由 `libdimentio.m` 内部完成。
⇒ `krw.h` 这行 include 是**冗余依赖**（但在原树里它解析得到，因为 `fun/kpf/../krw.h` 存在；
在我们的新布局里 `fun/krw.h` 不存在，所以这行**必须**去掉 —— 见 §4 的 patch 03 说明）。
> 【已证】依据：`patchfinder.m` L49-L192 逐个函数体读过，无 `do_kread`/`kread64`/`kread32`/`kreadbuf`/`early_kread*`/`vtophys`/`phystokv` 调用。
> 注：`krw.h` → `fun.h` → `<mach/mach.h>` 是 `patchfinder.m` 拿 Mach 类型的间接来源，
> 但那几个类型已被 `libdimentio.h`（`kern_return_t` 经 `CoreFoundation` 带入）与
> `patchfinder.h`（`mach_port_t`）覆盖。§7.3 有验证清单。

#### `libdimentio.m`（1107 行，全文读过）

全文的外部 KRW 调用点**只有 1 个**：

| 行 | 内容 | 层 |
|---|---|---|
| **L266-L272** | `kread_buf_kfd()` → **`early_kreadbuf(kfd, addr, buf, sz)`** | **`fun/krw.m`（krw 层）** |

其余全部是 `static kread_buf`（L123 声明，L566 赋值为 `kread_buf_kfd`）的内部转发。

`early_kreadbuf` 的实现在 `fun/krw.m` L51-L70，它的调用链是：

```
early_kreadbuf(fun/krw.m L51)
  └─ early_kread32 (fun/krw.m L47)
       └─ early_kread64 (fun/krw.m L41)
            └─ kread  ← libkfd.h L207（libkfd 层！）
```

**⇒ 结论【已证】**：patchfinder 间接需要的 **只是 libkfd 层的 `kread()`**，
krw 层在这里只是「逐 4 字节转发 + 小端铺缓冲」的一层薄壳，没有额外的内核语义。

所以本工程可以只补一个 20 行的 `MFLibkfdKRead4()`（在 `MFKernelBridge.c` 里）替换掉
整个 `fun/`（18 个源文件 + 若干头文件），**并且功能等价**（逐 4 字节、小端、末尾截断，三条语义都照搬）。

> 反过来说：如果 patchfinder 真的需要 krw 层的 `do_kread(where)`（用全局 `_kfd`、无 kfd 参数），
> 那就必须把 `fun/krw.m` 连同 `fun/krw.h` → `fun.h` 一起编进来，并且要处理 §2.1 的重复符号
> （只能靠把桥接层改成 include `fun/krw.h`）。**这条岔路我们不必走。**

### 2.3 `libdimentio.m` 的其他外部依赖（逐条核实）

| 依赖 | 位置 | 是否真需要 |
|---|---|---|
| `<compression.h>` + `compression_decode_buffer` | L17 包含，**L253 调用** | **真需要**（编译期 + 链接期都真）。但只有 `pfinder_init_file()` 路径会执行它，而那条路径 `kernel_path == NULL` 时为死代码 —— **链接器仍会保留**（`kdecompress` 是 static 且被 `pfinder_init_file` 调用，`pfinder_init_file` 被 `pfinder_init` 调用） |
| `COMPRESSION_LZFSE` | L253 | 同上，`<compression.h>` 常量 |
| `<dlfcn.h>`（L18） | `dlsym`/`dlopen` | **不需要**。全文 grep `dlsym|dlopen` = 0 命中 |
| `<mach-o/fat.h>`（L19） | `FAT_MAGIC`/`struct fat_header`/`fat_arch` | 需要（L494-L518，`pfinder_init_file` 里解析 FAT） |
| `<mach-o/loader.h>` | 经 `libdimentio.h` L21 带入；`MH_MAGIC_64`/`LC_SEGMENT_64`/`LC_FILESET_ENTRY`/`section_64` | 需要，`pfinder_init_macho`/`pfinder_init_kernel` 大量使用 |
| `CommonCrypto/CommonCrypto.h` | 经 `libdimentio.h` L17 带入 | **只用到 1 个宏 `CC_SHA384_DIGEST_LENGTH`**（L45/L48 的函数原型里）。不需要链 CommonCrypto |
| `CoreFoundation/CoreFoundation.h` | 经 `libdimentio.h` L18 带入 | 需要（`CFStringRef`/`CFAllocatorRef` 出现在 `patchfinder.h` 的 IOKit 原型里；Foundation 已带） |
| `kIOMasterPortDefault` | L118 `extern` 声明 | **纯声明，零引用** → 不产生链接需求 |
| `IOObjectRelease` 等 IOKit 原型 | `patchfinder.h` L20-L27 | **零调用点**（全树 grep：只在 `patchfinder.h` 出现）→ **不需要 IOKit.framework** |
| `proc_pidinfo` / `mach_vm_write` / `mach_vm_read_overwrite` / `mach_vm_machine_attribute` | L106-L116 `extern` 声明 | **零调用点**，纯遗留 |
| `krw_0_*` / `kernrw_0_*` / `tfp0` / `kmem_fd` / `has_proc_struct_sz` / `dimentio()` / `dimentio_preinit()` | L102-L131 的 typedef/声明 | **全部是死声明**（grep 无调用） |

**⇒ 本轮唯一需要新增链接的系统库是 `libcompression.tbd`**（见 §5.1 的争议说明）。
IOKit、CommonCrypto、libz、libMobileGestalt **都不需要**
（上游 kfund 的 `PBXBuildFile` 里 IOKit 是被 `fun.m`/`ppl`/`utils.m` 那些文件拉进去的，我们不编它们）。

### 2.4 最小闭包（20 个文件）

```
libkfd.h                                    ← MFKernelBridge.c 的入口
libkfd/common.h                             ← 类型/assert/print/计时宏
libkfd/info.h                               ← info_init/info_run，16.6.1 改造点
libkfd/info/static_info.h                   ← 结构体布局 + T1SZ_BOOT + ARM64_LINK_ADDR
libkfd/info/dynamic_info.h                  ← kern_versions[]（kfund 版只剩 1 条 iOS 16.x 通用项）
libkfd/puaf.h                               ← PUAF 分派（include 下面 3 个）
libkfd/puaf/landa.h                         ← ★ 目标机唯一可用
libkfd/puaf/physpuppet.h                    ← 被 puaf.h 无条件 include
libkfd/puaf/smith.h                         ← 被 puaf.h 无条件 include
libkfd/krkw.h                               ← ★ krkw_helper_find_kfd_offsets：KASLR + patchfinder 调用链
libkfd/krkw/kread/kread_kqueue_workloop_ctl.h ← 被 krkw.h 无条件 include
libkfd/krkw/kread/kread_sem_open.h          ← ★ 我们要用的读后端
libkfd/krkw/kwrite/kwrite_dup.h             ← 被 krkw.h 无条件 include
libkfd/krkw/kwrite/kwrite_sem_open.h        ← ★ 我们要用的写后端
libkfd/perf.h                               ← ★ kernel_slide 的唯一来源
fun/kpf/patchfinder.h                       ← 导出 off_* / get_kernversion / run_kfd_patchfinder
fun/kpf/patchfinder.m                       ← ★ 真正跑 patchfinder
fun/kpf/libdimentio.h                       ← pfinder_t / pfinder_* 原型
fun/kpf/libdimentio.m                       ← ★ 1107 行 patchfinder 实现
LICENSE                                     ← MIT 合规
```

「被无条件 include」的意思是：`puaf.h` L13-L15 与 `krkw.h` L18-L19/L31-L32 把三个 PUAF、
两个 kread、两个 kwrite **统统 include 进来**，无论运行时选哪个。
所以想在编译层「只放开需要的文件」是**做不到的** —— 真正能省下的只有：
`kfd.xcodeproj/`、`ContentView.swift`、`kfdApp.swift`、`Assets.xcassets/`、
`Preview Content/`、`writeups/`、`Info.plist`、`kfd.entitlements`、
以及 `fun/` 下除 `kpf/` 之外的全部（18 个文件）。这已经砍掉了原始 45 个文件的 56%。

---

## 3. 问题 3：min/max 宏污染 → 纯 C 桥接

`libkfd/common.h` L24-L25：

```c
#define min(a, b) (((a) < (b)) ? (a) : (b))
#define max(a, b) (((a) > (b)) ? (a) : (b))
```

这两个函数式宏一旦进入 C++（`std::min` / `std::max` / `<algorithm>` / STL 内部实现）必然炸。
本工程业务侧大量 `.mm`（ObjC++）。

**规避方案（已落地）**：

| 文件 | 是否含 libkfd | 语言 | 说明 |
|---|---|---|---|
| `Kernel/MFKernelBridge.h` | ❌ | 纯 C | 只 `#include <stdint.h>` / `<stdbool.h>`；枚举值手写为 `MF_*` 宏 |
| `Kernel/MFLibkfdHost.h` | ❌ | 纯 C | 只声明 `MFLibkfdKRead4` |
| `Kernel/MFKernelBridge.c` | ✅ **唯一** | C（`.c` 而非 `.mm`） | include 顺序见 §7.2 |
| 业务 `.mm` | ❌ | ObjC++ | 只 include `MFKernelBridge.h` |

> 反面教材：`MFKernelBridge.c` 若命名成 `.mm`，clang 会按 ObjC++ 编译，
> `min/max` 宏立刻与 libc++ 冲突。**必须是 `.c`**。

---

## 4. 文件清单（源路径 → 目标路径 → 为什么需要 → 依赖了谁）

`SRC` = `%TEMP%\kfund\kfund-main`，`KFD` = `%TEMP%\kfund\kfund-main\kfd`，
`DST` = `app\Sources\Kernel\`。

### 4.1 libkfd 层（15 个，全部【已证】必需）

| # | 源路径 | 目标路径 | 为什么需要 | 依赖了谁 | 依据 |
|---|---|---|---|---|---|
| 1 | `KFD\libkfd.h` | `KFD\libkfd.h` | 全库入口；定义 `kopen/kread/kwrite/kclose` 与 `struct kfd` | `libkfd/{common,info,puaf,krkw,perf}.h` | L15、L143-146 |
| 2 | `KFD\libkfd\common.h` | `KFD\libkfd\common.h` | `u8..u64` 类型、`assert*` 宏、`print*` 宏、`pages()` | 系统头 | L8-20 |
| 3 | `KFD\libkfd\info.h` | `KFD\libkfd\info.h` | `info_init`（设 `t1sz_boot`/`arm64_link_addr`）、`info_run`（拿 `current_proc` 等） | `info/dynamic_info.h`、`info/static_info.h` | L8-9、L49、L131 |
| 4 | `KFD\libkfd\info\static_info.h` | 同 | 全部内核结构体布局 + `arm64_link_addr` / `t1sz_boot` 运行时变量 | 无 | L12-13、L23-24 |
| 5 | `KFD\libkfd\info\dynamic_info.h` | 同 | `kern_versions[]`（kfund 版：1 条通用 iOS 16.x）+ **include `fun/kpf/patchfinder.h`** | `fun/kpf/patchfinder.h` | L8、L34 |
| 6 | `KFD\libkfd\puaf.h` | 同 | `puaf_init/run/cleanup/free` 分派 | `puaf/{landa,physpuppet,smith}.h` | L13-15 |
| 7 | `KFD\libkfd\puaf\landa.h` | 同 | ★ 16.6.1 上唯一可用 PUAF（CVE-2023-41974） | 无 | 调研报告 §1.1 |
| 8 | `KFD\libkfd\puaf\physpuppet.h` | 同 | 被 `puaf.h` 无条件 include（16.4 已修，仅编译需要） | 无 | `puaf.h` L14 |
| 9 | `KFD\libkfd\puaf\smith.h` | 同 | 同上（16.5.1 已修，仅编译需要，26KB） | 无 | `puaf.h` L15 |
| 10 | `KFD\libkfd\krkw.h` | 同 | ★`krkw_helper_find_kfd_offsets`：KASLR 破解 + 调 patchfinder + 回填 9 个 offset | `krkw/kread/*`、`krkw/kwrite/*`、`dynamic_info.h` 的 `off_*` | L163-228 |
| 11 | `KFD\libkfd\krkw\kread\kread_kqueue_workloop_ctl.h` | 同 | 被 `krkw.h` 无条件 include（16.5+ 已废，仅编译需要） | 无 | `krkw.h` L18 |
| 12 | `KFD\libkfd\krkw\kread\kread_sem_open.h` | 同 | ★ 读后端；**反向 include `fun/kpf/`** | `fun/kpf/libdimentio.h`、`fun/kpf/patchfinder.h` | L8-9 |
| 13 | `KFD\libkfd\krkw\kwrite\kwrite_dup.h` | 同 | 被 `kwrite_sem_open.h` 转调（真正的写语义在这里） | 无 | `kwrite_sem_open.h` L42/L50 |
| 14 | `KFD\libkfd\krkw\kwrite\kwrite_sem_open.h` | 同 | ★ 写后端 | `kwrite_dup.h`、`kread_sem_open.h` | L34、L42 |
| 15 | `KFD\libkfd\perf.h` | 同 | ★ `kernel_slide` 的唯一来源；`mf_get_kslide()` 读的 `perf.kernel_slide` | 系统 + `dynamic_info` | L107-109 |

### 4.2 fun/kpf 层（4 个，全部【已证】必需）

| # | 源路径 | 目标路径 | 为什么需要 | 依赖了谁 | 依据 |
|---|---|---|---|---|---|
| 16 | `KFD\fun\kpf\patchfinder.h` | `KFD\fun\kpf\patchfinder.h` | 导出 `get_kernversion` / `get_vm_kernel_link_addr` / `run_kfd_patchfinder` / `import_kfd_offsets` / `save_kfd_offsets` / 9 个 `off_*` | `<Foundation>` | L29-47 |
| 17 | `KFD\fun\kpf\patchfinder.m` | 同 | ★ `run_kfd_patchfinder` 主体 + `get_vm_kernel_link_addr`（M1/M2 基址） | `patchfinder.h`、`libdimentio.h`、`<sys/mount.h>`；**已删** `krw.h` | L49-113、L186-192 |
| 18 | `KFD\fun\kpf\libdimentio.h` | 同 | `pfinder_t`、`kaddr_t`、`pfinder_*` 原型 | `<CommonCrypto>`、`<CoreFoundation>`、`<mach-o/loader.h>` | L17-100 |
| 19 | `KFD\fun\kpf\libdimentio.m` | 同 | ★ 1107 行 patchfinder 实现 | `patchfinder.h`、`libdimentio.h`、`<compression.h>`、`MFLibkfdHost.h`(新) | L15-26 |

### 4.3 许可

| # | 源路径 | 目标路径 | 为什么 |
|---|---|---|---|
| 20 | `kfund-main\LICENSE` | `KFD\LICENSE` | MIT 许可要求随源码分发 |

### 4.4 明确**不**拷

| 源路径 | 理由 |
|---|---|
| `kfd.xcodeproj/**` | 上游示例工程；本工程用自己的 `project.yml` + XcodeGen |
| `kfd/ContentView.swift`、`kfd/kfdApp.swift` | 上游示例 UI，与本 App 无关 |
| `kfd/Assets.xcassets/**`、`kfd/Preview Content/**` | 示例资源 |
| `kfd/Info.plist`、`kfd/kfd.entitlements` | 示例工程配置；本工程有 `Support/Info.plist` 与 `Support/entitlements.plist` |
| `kfd/kfd-Bridging-Header.h` | 上游只让 Swift 看 `fun/**`；本工程走 `MFKernelBridge.h` |
| `writeups/**`（含 5 篇 md + 18 张 png，约 18MB） | 参考文档，留在 `%TEMP%` 与调研报告引用即可 |
| `kfd/fun/**` 除 `kpf/`（18 个 .m/.c/.h） | ★ **本工程不用**：见 §2.1/§2.2 |
| `kfd/libkfd/perf.h` 以外的…（无，perf.h 要保留） | — |
| `macos_kfd.c`、`Makefile` | macOS 示例 |

### 4.5 新增（本工程自写，4+1 个）

| 目标路径 | 语言 | 作用 |
|---|---|---|
| `Kernel/MFKernelBridge.h` | C | 纯 C 对外接口（不含 libkfd.h） |
| `Kernel/MFKernelBridge.c` | **C** | ★ 唯一 include `libkfd.h` 的 TU；失败钩子 + 全部导出实现 + `MFLibkfdKRead4` |
| `Kernel/MFLibkfdHost.h` | C | `MFLibkfdKRead4` 原型（给 `libdimentio.m` 用） |
| `Kernel/kfd/vendor/*.orig`（4 个） | — | 上游原样文件，仅供 diff / 生成 patch，**不参与编译** |
| `docs/patches/*.patch`（4 个）+ `scripts/gen_kfd_patches.py` | — | patch 记录与再生成 |

> 原计划还要一个 `MFLibkfdHost.c`（放 `MFLibkfdKRead4` 与 panic 钩子）。实际落地时发现
> 它必须也 include `libkfd.h` 才能调 `kread()`，而这会与「唯一 TU」的精神冲突（虽然技术上
> 两个 TU 各持一份定义也能链接，但会**两份 `kern_versions[]`**、两份 `kfd_init`…）。
> 最终把 `MFLibkfdKRead4` 与 `mf_kfd_fail_hook` 都放进 `MFKernelBridge.c`，
> **`MFLibkfdHost.c` 已删除**，`MFLibkfdHost.h` 只留原型。

---

## 5. 与上游 felix-pb 版的差异对照

上游版（`docs/_archive_kfd_upstream/kfd/`）是 43 个文件；kfund 版是 45 个。
两版**同名文件 21 个**，其中真正语义不同的是 5 个核心头：

### 5.1 `info.h`（差异最大）

| 项 | felix-pb 上游 | kfund |
|---|---|---|
| `info_init` 版本匹配 | `kern.version` 前缀 `memcmp` 遍历 `kern_versions[]`，不中即 `assert_false("unsupported osversion")` | **整段注释掉**（L118-128），永远 `kid.env.vid = 0`（L93） |
| 机型分支 | 无 | **新增** L106-112：`T8120/T8103/T8112 → t1sz_boot = 17`，否则 25 |
| 内核链接基址 | 编译期常量 `ARM64_LINK_ADDR` | **新增** L114：`arm64_link_addr = get_vm_kernel_link_addr()`（运行时） |
| 偏移回填 | 无（靠静态表） | 注释掉 L95-104 的静态回填（改由 `krkw.h` 在运行时回填） |

> ⇒ 这就是调研报告 §2.2 表格里三个「必须处理的问题」在代码层的落点。

### 5.2 `krkw.h`（+3137 字节，新增整个 patchfinder 调用链）

| 项 | felix-pb 上游 | kfund |
|---|---|---|
| `krkw_run` | `void`，直接跑 | **`int`**：`krkw_helper_grab_free_pages` 失败返回 -1（L97-98） |
| **`krkw_helper_find_kfd_offsets`** | **不存在** | **★ 新增 L163-228**：`import_kfd_offsets()` → 破 KASLR（扫 `0x100000cfeedfacf`）→ `run_kfd_patchfinder()` → 回填 9 个 `off_*` |
| `krew_helper_run_allocate` 尾部 | 直接 `find_proc` | 先判 `!current_proc` 再 `krkw_helper_find_kfd_offsets` + `find_proc`（L304-307） |

### 5.3 `libkfd.h`

| 项 | felix-pb 上游 | kfund |
|---|---|---|
| `kopen` 返回 | `return kfd` | `return (u64)(kfd)` 并加 `int fail` / `retry:` 标签（L169、L183-197） |
| landa 重试 | 无 | **新增 L187-197**：`krkw_run` 失败且 `puaf_method == puaf_landa` 时，把 kfd 清零重来（`goto retry`） |
| 配置宏 | `#define CONFIG_* 1` 硬编码 | 仍是硬编码 ★ **我们在 patch 04 里改成了 `#ifndef` 守卫** |

> ★ **风险提示【已证】**：这个 `goto retry` 是**无限循环**。若 landa 在某台机器上
> 恒定失败（例如 PUAF 用不满那个 `grabbed_free_pages_max = 400000` 循环，或 16GB 机型），
> `mf_kopen` 会**永不返回**。`MFKernelBridge.c` 目前无法给它加超时
> （补丁点太深、改动太大）。**建议 UI 层把 `mf_kopen` 放到后台线程 + 自己设超时提示**，
> 或后续在 patch 02 里顺手给 `retry:` 计一个失败次数上限。见 §9.6。

### 5.4 `info/static_info.h`

| 项 | felix-pb 上游 | kfund |
|---|---|---|
| `ARM64_LINK_ADDR` | `#define ARM64_LINK_ADDR 0xFFFFFFF007004000`（编译期常量） | **`uint64_t arm64_link_addr = 0;` + `#define ARM64_LINK_ADDR arm64_link_addr`**（L12-13，运行时变量） |
| `T1SZ_BOOT` | `#define T1SZ_BOOT 17`（编译期常量） | **`unsigned long long t1sz_boot = 0;` + `#define T1SZ_BOOT t1sz_boot`**（L23-24） |
| 结构体定义 | 相同 | 相同 |

> ⇒ 这两处「常量变变量」是 M1/M2 支持的**技术前提**，也是为什么
> `mf_get_kbase()` 必须写成 `ARM64_LINK_ADDR + perf.kernel_slide`（读运行时变量）而不是写死常量。

### 5.5 `info/dynamic_info.h`

| 项 | felix-pb 上游 | kfund |
|---|---|---|
| `kern_versions[]` 条目数 | 4 条（16.5/T8120、16.6/T8101、macOS 13.4、13.5） | **1 条**「`Darwin Kernel Version 22.x.x / arm64e`」通用项 + 3 条注释掉 |
| `proc__object_size` | 每条硬编码（0x0730/0x0778…） | **通用项里是 0**，等 runtime patchfinder 回填 |
| `kernelcache__*` | 每条硬编码 VA | **全部 0**，等 runtime patchfinder 回填 |
| `perf_supported` | 按条区分 | **通用项 = `true`**（对 iOS 16.x 成立） |
| 新增 | — | **L8 `#include "../../fun/kpf/patchfinder.h"`** ← libkfd ↔ fun/kpf 的耦合点 |

### 5.6 `common.h`

| 项 | felix-pb 上游 | kfund |
|---|---|---|
| `assert` 宏 | `sleep(30)` + `exit(1)` | **完全相同**（kfund 没改） |
| 其余 | — | 仅空白/注释差异 |

> ⇒ **「卡 30 秒闪退」这个体验问题是 kfund 也没解决的**，必须我们自己 patch（§6）。

### 5.7 两版同名文件清单（21 个）

```
libkfd.h
libkfd/common.h            libkfd/info.h              libkfd/krkw.h
libkfd/perf.h              libkfd/puaf.h
libkfd/info/static_info.h  libkfd/info/dynamic_info.h
libkfd/krkw/kread/kread_kqueue_workloop_ctl.h
libkfd/krkw/kread/kread_sem_open.h
libkfd/krkw/kwrite/kwrite_dup.h
libkfd/krkw/kwrite/kwrite_sem_open.h
libkfd/puaf/landa.h        libkfd/puaf/physpuppet.h   libkfd/puaf/smith.h
README.md                  Makefile                   macos_kfd.c
kfd/ContentView.swift      kfd/kfd-Bridging-Header.h  kfd/kfdApp.swift
```
（上表 5 个加了 ★ 语义差异；其余 16 个仅空白/注释/许可头差异。）

---

## 6. 问题 3（重点）：把 `sleep(30) + exit(1)` 改造成「返回错误码 + 错误字符串」

### 6.1 上游的失败模型（读遍全库后的全貌）

| 位置 | 失败时的行为 | 可恢复？ |
|---|---|---|
| `common.h` L117-126 `assert(cond)` | print → `sleep(30)` → `exit(1)` | ❌ |
| `common.h` L134-138 `assert_false(msg)` | print → `assert(false)` | ❌ |
| `common.h` L140-147 `assert_bsd(stmt)` | print errno → `assert(kret == KERN_SUCCESS)` | ❌ |
| `common.h` L149-156 `assert_mach(stmt)` | print `mach_error_string` → `assert(...)` | ❌ |
| **`krkw.h` L212-215** | `printf` → **`exit(1)`** | ❌ |
| `krkw.h` L186-207 KASLR 扫描 | `while (true) { … kerntask_tte_page -= 0x1000; }` | ❌ **可能死循环**（见 §9.2） |
| `krkw.h` L97-98 / L159-160 | `return -1` / 只打印警告 | ✅（landa 会 `goto retry`） |
| `libkfd.h` L187-197 | landa 重试 | ⚠️ **无限** |

⇒ 上游**只有一条**失败路径是返回错误的（`krkw_helper_grab_free_pages`），其余全是退出进程。
所以「只包一层返回值检查」是不够的，**必须动 assert 宏**。

### 6.2 改造方案（已落地）

核心思路：**把 `assert` 宏的目标从 `exit(1)` 换成宿主提供的失败钩子；
宿主用 `setjmp/longjmp` 把控制流收回 `mf_kopen()`。**

```
                 ┌──────────────────────────────┐
 mf_kopen() ───► │ setjmp(g_fail_jmp)           │
   ▲             │ g_fail_armed = 1             │
   │             │ kopen(...)                   │
   │             │   └─ libkfd 内部任意 assert  │
   │             │        └─ mf_kfd_fail_hook() │
   │             │             └─ longjmp ──────┼──┐
   │             └──────────────────────────────┘  │
   └───────────────────────────────────────────────┘
        setjmp 返回 1 → mf_kopen 返回 -1
        g_err / g_site 已由钩子填好 → mf_last_error()
```

四处 patch（`docs/patches/`，均可对上游原样文件重放）：

| patch | 文件 | 改动 | 行数 |
|---|---|---|---|
| `01-libkfd-common-assert-hook.patch` | `libkfd/common.h` | ① assert 宏 → `mf_kfd_fail_hook(#condition, __FILE__, __LINE__)`<br>② 补 `#include <string.h>`（上游用了 `memcmp`/`memcpy`/`strerror`/`bzero` 却只靠 `<stdio.h>` 间接带入，iOS SDK 上不保证） | +27 −9 |
| `02-libkfd-krkw-no-exit.patch` | `libkfd/krkw.h` | `printf + exit(1)` → `print_failure + mf_kfd_fail_hook` | +4 −2 |
| `03-libdimentio-host-kread.patch` | `fun/kpf/libdimentio.m` | ① 去掉 `#include "../krw.h"`<br>② `early_kreadbuf` → `MFLibkfdKRead4` | +8 −2 |
| `04-libkfd-config-ifndef.patch` | `libkfd.h` | `CONFIG_ASSERT/PRINT/TIMER` 加 `#ifndef` 守卫，允许 `-DCONFIG_PRINT=0` | +11 −1 |
| `05-kpf-patchfinder-drop-krw-include.patch` | `fun/kpf/patchfinder.m` | 删 `#import "krw.h"`（解析不到，见 §7.5）+ 显式补 `<stdbool.h>`/`<stdlib.h>`/`<string.h>` | +11 −1 |

四处 patch 与第五处的分工：01-04 是**行为改造**（错误处理 / 配置开关），
05 是**依赖闭包收口**（让 `fun/` 可以整目录不编）。

**关键安全性**：`mf_kfd_fail_hook()` 里若发现 `g_fail_armed == 0`（没人 setjmp），
就退回上游行为 `sleep(30) + exit(1)`。于是：
- 在 App 里 → 断言变成返回值，进程存活；
- 有人把 libkfd 单独拿去编（如 `macos_kfd.c`）→ 行为与上游一致，不会静默吞错。

### 6.3 改造后仍然做不到的事（必须向产品如实交代）

| 事项 | 说明 |
|---|---|
| **内核态可能已脏** | `longjmp` 只是让用户态复活。若断言发生在 `puaf_run` 成功之后（PUAF 页已喷入内核），那些页不会被归还 → 【已证】上游 writeup 说这会导致 `page still has mappings` panic。**所以失败后不要在同一进程内反复重试** |
| `sleep(30)` 无法完全消除 | 只有 `mf_kfd_fail_hook` 的兜底分支会 `sleep(30)`；正常路径（armed）已无延迟 |
| `goto retry` 无限循环 | 见 §5.3 与 §9.6 |
| `mf_kopen` 失败后无法安全 `kclose` | 失败时 `g_kfd` 已被置 NULL（`MF_MARK_FAILED()`），丢弃那个半残的 `struct kfd*`。这是**有意的**：上游 writeup 说错态清理比泄漏更危险 |
| 清理路径（`kclose`） | 已用同一套 setjmp 兜住，避免用户点「关闭」时闪退 |

### 6.4 UI 契约（给业务侧）

```c
#include "MFKernelBridge.h"

mf_set_verbose(1);                 // 开发期打开 stderr 诊断
int rc = mf_kopen_default();       // landa + sem_open/sem_open + 2048 页
if (rc != 0) {
    // rc == -1 → libkfd 内部失败；-2 → 已打开；-3 → 参数非法
    NSLog(@"kfd failed: %s  (%s)  [stage: %s]",
          mf_last_error(),         // "assertion failed: (...) at common.h:123"
          mf_last_error_site(),    // "common.h:123"
          mf_last_stage());        // "kopen: start (...)"/"kopen: FAILED (...)"
    return;                        // ← 不要立刻重试；提示用户重启 App
}
// 成功
NSLog(@"kbase=0x%llx kslide=0x%llx", mf_get_kbase(), mf_get_kslide());
NSLog(@"perf.kernel_slide=0x%llx", mf_get_kslide());
NSLog(@"kernel_proc=0x%llx current_proc=0x%llx",
      mf_get_kernel_proc(), mf_get_current_proc());
mf_kclose();
```

---

## 7. 编译/链接设置与 include 顺序

### 7.1 `app/project.yml` 改动

| 项 | 原 | 现 | 理由 |
|---|---|---|---|
| `sources.excludes` | `Render/imgui/**`、`Kernel/kfd/**`、`Kernel/kfund/**` | `Render/imgui/**`、**`Kernel/kfd/vendor/**`** | 逐文件放开；`vendor/` 只放 `.orig` 参考件，不编译 |
| 显式 sources | 6 个 imgui | + `MFKernelBridge.{c,h}`、`MFLibkfdHost.h`、`kfd/fun/kpf/{patchfinder,libdimentio}.m`、`kfd/libkfd.h` | XcodeGen 必须显式看见 |
| `HEADER_SEARCH_PATHS` | `…/Kernel/kfd/kfd` | **`…/Kernel/kfd`** + **`…/Kernel`** | `libkfd.h` 内部按 `"libkfd/common.h"` 相对包含，所以路径要指向 `libkfd.h` 所在目录；`MFKernelBridge.c` 写的是 `"kfd/libkfd.h"` |
| `dependencies` | — | + `libcompression.tbd` | `libdimentio.m` L253 |
| `OTHER_CFLAGS` | 无 | + `-Wno-deprecated-declarations`、`-Wno-deprecated-non-prototype` | `sem_open`/`syscall`/`ioctl` 已 deprecated；上游 macOS Makefile 也用前一个 |

### 7.2 `MFKernelBridge.c` 的 include 顺序（**必须照此**）

```c
#include "MFKernelBridge.h"    // 1. 纯 C 公共头（无 libkfd）
#include "MFLibkfdHost.h"      // 2. MFLibkfdKRead4 原型
/* 3. 配置开关 —— 必须早于 libkfd.h */
#define CONFIG_ASSERT 1
#define CONFIG_PRINT  0
#define CONFIG_TIMER  1
#include "kfd/libkfd.h"        // 4. ★ 全工程唯一
#include "kfd/fun/kpf/patchfinder.h"
#include <errno.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
```

理由：
- 第 3 步必须在第 4 步之前 —— patch 04 把它改成了 `#ifndef` 守卫。
- `libkfd.h` 内部会 include `info.h` → `dynamic_info.h` → `fun/kpf/patchfinder.h`，
  也会经 `krkw.h` → `kread_sem_open.h` → `fun/kpf/{libdimentio,patchfinder}.h`
  再把同一批文件带一次（有 include guard，安全）。
- 第 4 步之后 `kread` 等符号才在作用域内，`MFLibkfdKRead4` 的实现才能调它。

### 7.3 `fun/kpf/libdimentio.m` 的 include 顺序

```c
#include "patchfinder.h"      // 带 <Foundation>，提供 mach_port_t / CFStringRef 等
#include "libdimentio.h"      // kaddr_t / pfinder_t
#include "MFLibkfdHost.h"     // [patch 03] 新增，替换 "../krw.h"
#include <compression.h>
#include <dlfcn.h>
#include <mach-o/fat.h>
#include <mach/mach.h>
...
/* [patch 03] "../krw.h" 已删除 */
```

**必须保留 `patchfinder.h` 在最前**：它 L11 `#import <Foundation/Foundation.h>`，
是 `mach_port_t` / `CFStringRef` / `CFAllocatorRef` / `UInt32` 的来源；
`libdimentio.h` 只用它们、不带入。

【未证】`patchfinder.m` 去掉 `#import "krw.h"` 后是否还缺类型 —— 见 §7.5。

### 7.4 语言与扩展名纪律

| 文件 | 扩展名 | 原因 |
|---|---|---|
| `MFKernelBridge.c` | `.c` | **不能是 `.mm`**：`min/max` 宏会与 libc++ 冲突（§3） |
| `MFLibkfdHost.h` | `.h` | 纯 C 原型，可被 `.m` 与 `.mm` 一起包含 |
| `MFKernelBridge.h` | `.h` | 同上 |
| `patchfinder.m` / `libdimentio.m` | `.m` | 用 Foundation；**不是** `.mm`（上游也是 `.m`） |

### 7.5 `patchfinder.m` 的 `#import "krw.h"` —— 已删除（patch 05）

`patchfinder.m` L13 原本是 `#import "krw.h"`。在新布局下 `fun/krw.h` **不存在**
（不拷 `fun/`），所以这行**解析不到，会直接编译失败**。

**已按选项 A 修掉**（`docs/patches/05-kpf-patchfinder-drop-krw-include.patch`）：

```objc
#include <stdbool.h>   // ← 新增：bool
#include <stdlib.h>    // ← 新增：strdup / NULL
#include <string.h>    // ← 新增：strstr / strcmp

#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import "patchfinder.h"
#import "libdimentio.h"
/* krw.h 已删除 */
```

**删除的正当性（逐行核实，不是猜）**：`patchfinder.m` 全文 **192 行**，
对 krw 层的 `do_kread` / `do_kwrite` / `kread8/16/32/64` / `kread64_smr` /
`kreadbuf` / `kwrite8/16/32/64` / `early_kread*` / `unsign_kptr` / `vtophys` /
`phystokv` / `get_kslide` / `get_kernproc` / `get_selftask` / `get_selfpmap` /
`get_kerntask` / `kread64_ptr` / `do_vtophys` / `do_phystokv` 的调用 =
**0 命中**。它只用 `pfinder_*`（`libdimentio.m`）与系统调用。

`krw.h` 原本带进来的 `<mach/mach.h>` / `<stdio.h>` 已由 `patchfinder.h`
（→ `<Foundation>`）与 `<sys/sysctl.h>` / `<sys/mount.h>` 覆盖。
三个新增的标准库头是**防御性**的：把原本「靠 Foundation 间接带入」变成显式依赖。

> 备选（若上机发现仍缺符号）：`#include <mach/mach.h>` 补进 `patchfinder.m`。
> **未证**：本机无 Xcode，无法编译验证。这是 §9.11 第 1 条的残余风险，已大幅降低。

---

## 8. 编译集成：现状与已知阻塞

### 8.1 需要的系统库（最终结论）

| 库 | 需要？ | 依据 |
|---|---|---|
| `libcompression.tbd` | **是** | `libdimentio.m` L17 + L253 |
| `Foundation.framework` | 是（已有） | `patchfinder.{h,m}`、`libdimentio.m` |
| `IOKit.framework` | **否** | `patchfinder.h` L20-27 只有原型，零调用点（§2.3） |
| `CommonCrypto` | **否** | 只用了 `CC_SHA384_DIGEST_LENGTH` 一个宏 |
| `libz.tbd` / `libMobileGestalt.tbd` | **否** | 上游 `PBXBuildFile` 里没有它们（只在 `PBXGroup` 里挂着，未加入任何 build phase） |
| `UIKit.framework` | 是（已有） | 业务侧 |

### 8.2 【未证】`-lcompression` 到底可否省掉

iOS 的 `libcompression` 自 iOS 11 起以**独立动态库** `/usr/lib/libcompression.dylib` 存在。
争议点在于：iOS SDK 里**是否存在 `libcompression.tbd`**，以及 `libSystem.tbd` 有没有
re-export 它的符号。

- 若 `libSystem.tbd` 有 re-export → 不写 `-lcompression` 也能链接成功。
- 若没有 → 必须显式链接。

**我们的处理**：在 `project.yml` 里显式加了 `- sdk: libcompression.tbd`。
若该文件在目标 SDK 里不存在，XcodeGen/xcodebuild 会报错 —— 那时删掉这一行再试即可。
重复链接无害，所以这个选择的期望损失最小。

【未证】本机无 Xcode，无法验证。**上机/CI 第一次构建时优先看这一条。**

### 8.3 【已证】`libkfd.h` 的两处隐式依赖已补

- `common.h` 用 `strerror()`（L144）/`memcmp`/`memcpy`/`bzero`，但只 include 了 `<stdio.h>`。
  patch 01b 补了 `<string.h>`。
- `common.h` 用 `timersub`（L174，`timer_end` 宏），来自 `<sys/time.h>`。
  【推断】`<mach/mach.h>` → `<sys/time.h>` 链上能拿到，暂未显式补。
  **若编译报 `timersub` 未声明，在 `common.h` 补一行 `#include <sys/time.h>`。**

### 8.4 ⚠️ 与本任务无关、但会挡住交付的既有问题

`app/project.yml` 的 `FindMy.settings.base` 设了：

```yaml
ONLY_ACTIVE_ARCH: NO
ARCHS: arm64
```

而 `options`（项目级）里**没有** `ONLY_ACTIVE_ARCH`。kfund 上游工程在
**project 级** Debug 配 `ONLY_ACTIVE_ARCH = YES`、target 级不设。

在 Xcode 的语义里，`ONLY_ACTIVE_ARCH` 只在 **Debug** 配置下有意义（Release 恒为 NO），
所以**理论上现在的设置是对的**。

但 `scripts/` 与 `.github/` 里的云构建脚本若用默认 `Debug` 配置跑 `xcodebuild`，
在 Apple Silicon runner 上 active arch 是 arm64（OK），在 Intel runner 上会是 x86_64（✗）。
【推断】建议在 `options` 加 `ONLY_ACTIVE_ARCH: NO` 并且构建命令显式带 `-configuration Release`。
**未验证**，因为无法在本机跑 xcodebuild。

---

## 9. 风险与未决项

### 9.1 【已证】`perf` 必须跑起来，`kernel_slide` 全靠它

`perf.h` L69-71 / L92-94：`if (!dynamic_info(perf_supported)) return;`
kfund 的 `dynamic_info.h` L39 给 iOS 16.x 通用项设 `perf_supported = true`
⇒ **perf_init/perf_run 都会真跑**，不会像调研报告 §3.3 猜的那样「跳过」。

而 `kernel_slide` 只在 `perf_run()` 里算（L107-109）：

```c
u64 vn_kqfilter = UNSIGN_PTR(fo_kqfilter);
u64 kernel_slide = vn_kqfilter - dynamic_info(kernelcache__vn_kqfilter);   // L107
```

`kernelcache__vn_kqfilter` 是 patchfinder 回填的 9 个值之一（`krkw.h` L226）。
⇒ **patchfinder 任何一个 pfinder_* 返回 0，`run_kfd_patchfinder` 就 `return -1`
→ `mf_kfd_fail_hook` → `mf_kopen` 返回 -1。** 这是良性失败，符合预期。

**`mf_get_kbase()` 的实现依据**：`perf.h` 只存 `kernel_slide`，不存 kbase。
所以 kbase = `ARM64_LINK_ADDR + kernel_slide`（`ARM64_LINK_ADDR` 已是运行时变量，
`static_info.h` L12-13）。同一个公式在 `perf.h` L108 用于 `kernel_base`。

### 9.2 【已证 · 高危】KASLR 扫描可能死循环

`krkw.h` L193-207：

```c
uint64_t kbase = 0;
while (true) {
    uint64_t val = 0;
    kread((u64)kfd, kerntask_tte_page, &val, sizeof(val));
    if (val == 0x100000cfeedfacf) { ... break; }
    kerntask_tte_page -= 0x1000;      // ← 无下界检查
}
```

若 `val` 永远不等于 `0x100000cfeedfacf`（例如 `kernel_task->vm_map` 偏移 0x28 在这个
内核版本上不对），这个循环会一路 `-= 0x1000` 读到 0 地址，然后继续回绕 —— **永不退出**。
表现：App 卡在「启动内核」不动。

**对策建议**：在 patch 02 里顺手给这个循环加下界检查（例如
`if (kerntask_tte_page < 0xffff000000000000ULL) { mf_kfd_fail_hook(...); }`）。
**当前未做**（本轮只做用户明确要求的 exit(1) 改造）。见 §10 待办第 3 条。

### 9.3 【已证】`kwrite` 不能写 0 —— 哪些路径会咬人

依据：`writeups/exploiting-puafs.md` L189-192（调研报告 §3.4 已收录）。

底层原因：`kwrite_sem_open` → `kwrite_dup_kwrite`（`kwrite_dup.h`）通过
**文件描述符 / 对象字段**表达要写的值，0 没有可表达的形式。

会咬人的具体位置（读代码得到）：

| 位置 | 想写什么 | 风险 |
|---|---|---|
| `perf.h` L196、L198 | `((volatile u32*)perfmon_device_uaddr)[4] = 0; [5] = 0;` | ⚠️ 这里**故意把缓冲置 0** 然后 `kwrite(..., size=8)` —— 但注释明确说「The value 0 cannot be written」，所以上游是**靠整 8 字节里其他非零字节带过去**的，不是直接写 0 |
| `perf.h` L195-201 | `pmdv_mutex[1] = -1; pmdv_allocated = true;`（非零） | ✅ 安全 |
| **业务侧** | 把某个 `u64` 字段「清 0」（如 `csflags`、`p_pid`、指针） | ❌ **会静默失败**。必须改成写非零值，或改上层字段 |

**桥接层的处理**：`mf_kwrite32/64` 照原样写，**不做拦截**（拦截会破坏 perf 的用法）。
但 `MFKernelBridge.h` 里把这条限制写进了注释，业务侧必须自己规避。

> 另外：`mf_kwrite32()` 的实现是「读回对齐的 8 字节槽 → 改 4 字节 → 整槽写回」，
> 这样当 `value == 0` 时**槽内其他字节非零**，有机会成功。但这不是保证。
> 【推断】—— 未上机验证，**不要依赖**。

### 9.4 【已证】fd 上限

`kread_sem_open.h`：

- L18：`kfd->kread.krkw_maximum_id = kfd->info.env.maxfilesperproc - 100;`
- L21-22：`krkw_method_data_size = (maximum_id + 1) * sizeof(i32) + sizeof(struct psem_fdinfo)` → **malloc 出来**
- L41-48 `kread_sem_open_allocate`：**为每个 id 开一个 `sem_open()` → 一个 fd**

⇒ 峰值 fd 用量 ≈ `maxfilesperproc - 100`。在 iOS 上 `kern.maxfilesperproc` 通常是 **10240**
⇒ 需要约 **10140 个 fd** 同时打开。

`info.h` L81-86 已经处理了这一点：

```c
usize size1 = sizeof(kfd->info.env.maxfilesperproc);
assert_bsd(sysctlbyname("kern.maxfilesperproc", &..., NULL, 0));
struct rlimit rlim = { .rlim_cur = maxfilesperproc, .rlim_max = maxfilesperproc };
assert_bsd(setrlimit(RLIMIT_NOFILE, &rlim));
```

**风险点**：
1. 若 App 已被沙箱/父进程把 `RLIMIT_NOFILE` 的 **hard limit** 压低，`setrlimit` 抬高会返回 `EPERM`
   → `assert_bsd` 失败 → 现在会变成 `mf_kopen` 返回 -1（不再闪退）✅
2. 启动前后**不要**有其他大量开 fd 的代码（sqlite/keychain/网络），否则 `sem_open` 中途 `EMFILE`
   → `assert(fd > 0)` 失败（`kread_sem_open.h` L44）→ 同上返回错误 ✅
3. `krkw_method_data` 需 malloc `(10140+1)*4 + sizeof(psem_fdinfo)` ≈ **40KB**，可忽略。

【未证】TrollStore 环境下 `RLIMIT_NOFILE` hard limit 实际值。**建议上机第一步就
`getrlimit(RLIMIT_NOFILE)` 打日志。**

### 9.5 【已证 · 时间与内存】第一次跑 patchfinder 要多久

`pfinder_init`（`libdimentio.m` L551-572）在 `kernel_path == NULL` 时走
`pfinder_init_kernel(pfinder, 0)`（L567）——**纯内存 patchfind，不读磁盘**。

它要做的事（`libdimentio.m` L429-488）：

1. 从 `kbase` 处 `kread_buf` 读 `mach_header_64`，遍历 `load_command`
2. 找到 `__TEXT_EXEC.__text` 段 → **`malloc(s64.size)` 然后把整段内核代码拷出来**（L457）
3. 找到 `__TEXT.__cstring` 段 → `calloc(size+1)` 拷出来（L463）
4. 之后所有 `pfinder_*` 都在**用户态内存副本**上做指令/字符串模式匹配
   （例如 `pfinder_proc_object_size` 扫 4 条连续指令 `0xAA1503E0 / 0x528104E1 / 0x52800102 / 0x52801103`）

**耗时预估【推断】**：

| 阶段 | 量级 | 说明 |
|---|---|---|
| 读 `__TEXT_EXEC.__text` | 内核代码段在 arm64e 上约 **20-40 MB** | 逐个 4 字节 `kread` ⇒ **5-10M 次** `sem_open`+`syscall` 往返。这是**绝对瓶颈** |
| 9 次 `pfinder_*` 扫描 | 每次线性扫 `sec_text`（最多 40MB / 4B = 10M 条指令） | 用户态内存扫描，快（毫秒~百毫秒级） |
| **总计** | 与 kfund 的 patchfinder 同量级 | 【未证】具体秒数。**kfund 把这段放在启动路径上，用户可接受**，说明不是分钟级，但**很可能是 10-60 秒级** |

**内存峰值【推断】**：`sec_text` 副本（20-40MB）+ `sec_cstring` 副本（几百 KB）
+ PUAF 页（`pages(2048)` = 32MB）+ `krkw_method_data`（40KB）≈ **60-75 MB**。
对 iPad 无压力，但要设好 watchdog 与进度提示。

> ★ 这是「第一次跑 patchfinder 需要多久」的诚实答案：**下界确定（不读磁盘）、
> 上界未证（取决于 kread 后端单次往返延迟 × 内核代码段大小）**。
> 首次运行成功后 `save_kfd_offsets()` 会写 plist 到 `Documents/kfund_offsets.plist`，
> 下次 `import_kfd_offsets()` 直接命中（L170）⇒ **第二次及以后秒开**。

### 9.6 【已证】landa 无限重试

见 §5.3。`libkfd.h` L183-197 的 `retry:` 没有次数上限。
`mf_kopen` 目前无法设超时。**建议**：UI 把 `mf_kopen` 放后台线程，
自己加「已等待 N 秒」提示；或在 patch 02 里给 retry 计数。
**未做**，见 §10 待办第 3 条。

### 9.7 【已证】不需要 `set_libdimentio_kernpath`

`libdimentio.m` L545-549 定义了 `set_libdimentio_kernpath()`，但
`patchfinder.m` **从未调用它**（grep 全树：只在 `libdimentio.m` L545 有定义、`libdimentio.h` L60 有原型）。
⇒ `kernel_path` 恒为 `NULL`（L96）⇒ `pfinder_init` 恒走内存路径（L567）。

**⇒ 调研报告 §4.5「若选路线 A，注意它需要读 kernelcache：要么联网下载，要么把
kernelcache 放进 IPA」这条结论需要修正**：kfund 的 patchfinder **不需要 kernelcache 文件**。
真正需要下载 kernelcache 的是 TrollInstallerX 那条独立路线（调研报告 §2.3 路线 C）。

### 9.8 【已证】`sem_open` 名字是硬编码的全局名

`kread_sem_open.h` L11：`const char* kread_sem_open_name = "kfd-posix-semaphore";`
L24 先 `sem_unlink()` 再 `sem_open(O_CREAT|O_EXCL)` ⇒ 会**踢掉别的进程正在用的同名信号量**。

**风险**：若同进程/同设备上有另一个 kfd 实例在跑（例如我们的 HUD 进程 + 主进程同时跑），
两个实例会互相破坏。**建议：kfd 只在主进程跑一次。**

### 9.9 【已证】`import/save_kfd_offsets` 的路径与失败行为

- `patchfinder.m` L124 / L158：`%@/Documents/kfund_offsets.plist`（`NSHomeDirectory()`）
- L130：`strcmp(get_kernversion(), saved_kern_version)` —— 版本串不一致就放弃缓存 ✅（正确）
- L176-180：写失败只打印并 `return -1`，**但 `run_kfd_patchfinder` 在 L110 调用它时忽略返回值**
  ⇒ 缓存写失败不影响本次运行 ✅
- 【已证 · 小内存泄漏】L164 `@(get_kernversion())` 与 L120、L187 的 `strdup` 都**不 free**。
  一次运行漏几百字节，可忽略，但 `mf_kernel_version()` 已做缓存避免 UI 轮询放大它。
- 【已证】`get_vm_kernel_link_addr()`（L186-192）每次调用都 `strdup`；
  `krkw.h` L208 与 `info_init` L114 各调一次 ⇒ 每次 kopen 漏 ~100 字节。

### 9.10 【已证】`T1SZ_BOOT` 三处必须一致

| 位置 | 赋值方式 |
|---|---|
| `libkfd/info.h` L109-112 | `strstr(kernversion,"T8120"/"T8103"/"T8112")` → `t1sz_boot = 17`，否则 **25** |
| `libkfd/info/static_info.h` L23-24 | `t1sz_boot` 是全局变量 |

`fun/krw.m` 的 `unsign_kptr`（L18-20）也用了 `T1SZ_BOOT`，但我们不编它。
`libdimentio.m` 有自己的 `static unsigned t1sz_boot;`（L121），由 `kxpacd()`（L143-148）使用
——【未证】它在 iOS 分支上是否被赋值。若是 0，`kxpacd()` 就退化成空操作（L145 `if (t1sz_boot != 0)`）。
**上机验证点**：若 patchfinder 找 `sec_text` 失败，第一个要查的就是这里。

对 **T8112（M2）**：`t1sz_boot = 17` ✅ 与调研报告 §2.2 一致。

### 9.11 【未证】列表

| # | 未证事项 | 影响 | 怎么验 |
|---|---|---|---|
| 1 | `patchfinder.m` 删掉 `#import "krw.h"` 后能否编过（已补 3 个标准库头，但仍无真机编译器验证） | **会阻塞构建** | CI 第一次构建；缺类型就补 `#include <mach/mach.h>` |
| 2 | `libcompression.tbd` 在目标 SDK 里是否存在 | **会阻塞构建** | CI 第一次构建；不存在就删掉那行 |
| 3 | `timersub` 是否可见 | 会阻塞构建 | 报错就补 `#include <sys/time.h>` |
| 4 | 16.6.1/T8112 的 `kern.version` 精确串 | `libdimentio.m` 的 `t1sz_boot` 分支未用它；`info_init` 也不用它 | 上机 `sysctl kern.version` |
| 5 | patchfinder 首次实耗秒数 | UX（进度提示/超时） | 上机打点 |
| 6 | 16.6.1 上 9 个 `pfinder_*` 是否全部能命中 | **决定成败** | 上机看 `kopen` 返回值 + `mf_last_error()` |
| 7 | `kern.maxfilesperproc` / `RLIMIT_NOFILE` hard limit | 决定 `sem_open` 能否开满 | 上机打日志 |
| 8 | `perf` 在 16.6.1 上是否真可用（有 9 个偏移但 perfmon 行为可能不同） | 决定 `kernel_slide`/kbase 是否有效 | 上机读 `mf_get_kbase()` 并校验低 12 位为 0 |
| 9 | landa 在 2048 页上的成功率 | 决定默认参数 | 20 次连测（调研报告 §7 已列） |
| 10 | `ONLY_ACTIVE_ARCH` 在 CI 的实际行为 | 可能出错架构包 | 见 §8.4 |

---

## 10. 待办（建议顺序）

- [x] ~~**P0** 修 `patchfinder.m` L13 的 `#import "krw.h"`~~
      **已修**（patch 05，删掉 + 显式补三个标准库头）。残余风险见 §9.11 第 1 条。
- [ ] **P0** CI 第一次构建：优先确认
      ① `libcompression.tbd` 是否存在（§8.2）；
      ② `timersub` 是否可见（§8.3，报错就补 `#include <sys/time.h>`）；
      ③ `patchfinder.m` 是否还缺 Mach 类型（缺则补 `#include <mach/mach.h>`）。
- [ ] **P1** 给 `krkw.h` L193-207 的 KASLR 扫描加下界检查（§9.2）；
      或接受「卡住 = 失败」并靠 UI 超时兜底。
- [ ] **P1** 给 `libkfd.h` L183-197 的 `retry:` 加次数上限（§9.6）。
- [ ] **P2** 上机最小验证：
      1. `mf_kernel_version()` 打印真实内核串；
      2. `mf_kopen_default()` 返回值 + `mf_last_stage()`；
      3. 成功则校验 `mf_get_current_proc()` 读出 `p_pid == getpid()`
         （用 `mf_kread32(proc + proc__p_pid)`，kfund 表里 `proc__p_pid = 0x60`）；
      4. 记录 patchfinder 耗时。
- [ ] **P2** `RLIMIT_NOFILE` / `kern.maxfilesperproc` 打点（§9.4）。
- [ ] **P2** 业务侧接入：`Kernel` 设置页（方法固定 landa + pages 可选 + 失败重试 + 友好提示）。
- [ ] **P3** 把 `docs/kfd-集成调研.md` §4.5 关于「patchfinder 需要 kernelcache」的表述
      按 §9.7 修正（kfund 路线不需要）。

---

## 11. 交付物索引

| 路径 | 说明 |
|---|---|
| `app/Sources/Kernel/kfd/**`（20 个） | §4 的文件闭包（19 源码/头 + LICENSE）；**14 个与上游逐字节一致**，5 个是刻意 patch |
| `app/Sources/Kernel/kfd/vendor/*.orig`（5 个） | 被 patch 的 5 个文件的上游原样版本 |
| `app/Sources/Kernel/MFKernelBridge.h` | 纯 C 对外接口（§6.4 的 UI 契约） |
| `app/Sources/Kernel/MFKernelBridge.c` | ★ 唯一 include `libkfd.h`；失败钩子 + 全部实现 + `MFLibkfdKRead4` |
| `app/Sources/Kernel/MFLibkfdHost.h` | `MFLibkfdKRead4` 原型（供 `libdimentio.m` 使用） |
| `docs/patches/01..05-*.patch` | 5 处最小改动的 unified diff |
| `scripts/gen_kfd_patches.py` | 从 `vendor/*.orig` 重算 patch |
| `docs/_archive_kfd_upstream/kfd/`（54 个） | 被替换掉的上游 felix-pb 版，留档对照 |
| `app/project.yml` | 放开 Kernel、加 `libcompression.tbd`、修 header 搜索路径 |

---

## 12. 上游原样性验证（本轮实际执行）

对 `%TEMP%\kfund\kfund-main\kfd\`（kfund 原件）与 `app\Sources\Kernel\kfd\` 逐一算 sha256：

**MODIFIED（5 个 —— 全部是刻意 patch，均已生成 .patch）**
```
libkfd.h                    ← patch 04  CONFIG_* 加 #ifndef 守卫
libkfd\common.h             ← patch 01  assert 宏 -> 失败钩子；补 <string.h>
libkfd\krkw.h               ← patch 02  printf+exit(1) -> 失败钩子
fun\kpf\patchfinder.m       ← patch 05  删 #import "krw.h"；补 3 个标准库头
fun\kpf\libdimentio.m       ← patch 03  删 "../krw.h"；early_kreadbuf -> MFLibkfdKRead4
```

**IDENTICAL（14 个 —— 一个字节都没动）**
```
libkfd\info.h                                    libkfd\info\static_info.h
libkfd\info\dynamic_info.h                       libkfd\puaf.h
libkfd\puaf\landa.h                              libkfd\puaf\physpuppet.h
libkfd\puaf\smith.h                              libkfd\krkw\kread\kread_kqueue_workloop_ctl.h
libkfd\krkw\kread\kread_sem_open.h               libkfd\krkw\kwrite\kwrite_dup.h
libkfd\krkw\kwrite\kwrite_sem_open.h             libkfd\perf.h
fun\kpf\patchfinder.h                            fun\kpf\libdimentio.h
```
（另：`LICENSE` 亦为原样拷贝。）

⇒ 满足纪律要求：**改动只有 5 处**（4 处错误处理/配置改造 + 1 处依赖收口），
全部落在 `docs/patches/` 里，可重放、可审计；其余 14 个文件与上游逐字节一致。

> 复现命令：
> ```powershell
> python scripts/gen_kfd_patches.py     # 重算 5 个 patch
> # 或人工 diff：把 app/Sources/Kernel/kfd/vendor/X.orig 与 app/Sources/Kernel/kfd/<X> 对比
> ```
