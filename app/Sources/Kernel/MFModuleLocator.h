//
//  MFModuleLocator.h — 模块定位
//
//  作用：从「进程名」一路拿到「模块加载基址」。
//
//  ── 为什么需要它 ──
//
//  UE4 的对象图全部是「模块基址 + 固定偏移」：
//      GWorld = Read<u64>(sLibBase + 0x178AA5E0);
//
//  白米饭也是同样的结构 —— 它用一个全局变量（原地址 0x100FF65D0）存这个基址，
//  那个全局的「写入点」在静态分析里没查到。现在清楚了：**它存的就是模块基址**。
//
//  ── 实现依据 ──
//
//  1) 《白米饭 · KFD到读取后端_完整链路报告》已证原版有这条路径：
//         task_info(TASK_DYLD_INFO) → mach_vm_read_overwrite 读 dyld_all_image_infos
//         → 读映像数组 → 读每个映像的路径 → 匹配模块名 → imageLoadAddress
//  2) mingyun 2.0.4 的 AttachIfNeeded()（0x100010970）证实了目标进程名：
//         strcpy(v7, "DeltaForceClient");
//         sLibBase = pzesa3a1tbpsun4w0j7();   // 取主模块加载基址
//     （该函数体未展开，但路径与 1) 一致）
//
//  ── 本实现的两条路 ──
//
//   路 A（默认）TASK_DYLD_INFO —— 官方 SPI，一次遍历拿到全部模块
//   路 B（兜底）mach_vm_region 扫描 —— 路 A 被拦时的替代
//
#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个已加载的模块
@interface MFModuleInfo : NSObject
@property (nonatomic, copy)   NSString *path;         // 完整路径
@property (nonatomic, copy)   NSString *name;         // 末段文件名
@property (nonatomic, assign) uint64_t base;          // 加载基址（★ 就是我们要的 sLibBase）
@property (nonatomic, assign) uint64_t size;          // 大小（mach_vm_region 才有，路 A 为 0）
@property (nonatomic, assign) BOOL     isMain;        // 是否主可执行文件

/// 人类可读大小（"381.2 MB" / "12.3 KB"）；路 A 拿不到大小时返回 "—"
- (NSString *)sizeText;
@end

@interface MFModuleLocator : NSObject

+ (instancetype)shared;

#pragma mark - 进程

/// 按进程名找 pid。失败返回 -1。
/// 对齐 mingyun 的 ut9av9srt3q4yz7ho80u()：按名字找进程
+ (pid_t)pidForProcessName:(NSString *)name;

/// 拿目标进程的 task port。失败返回 MACH_PORT_NULL。
/// 调用方负责 mach_port_deallocate。
+ (mach_port_t)taskPortForPid:(pid_t)pid;

#pragma mark - 模块

/// 列出目标进程的全部已加载模块（按基址升序）。
/// 失败时 items 为 nil，error 有内容。
+ (nullable NSArray<MFModuleInfo *> *)modulesForPid:(pid_t)pid
                                              error:(NSString *_Nullable *_Nullable)error;

/// 取「主模块」—— 也就是 UE4 那个几百 MB 的大模块。
///
/// 判定顺序（每一步都留痕，便于诊断）：
///   ① 路径里含已知的 UE4 特征名（libUE4 / UE4Game / 主可执行名）
///   ② 体积最大的那个（UE4 模块通常 300~600 MB，其余都是几十 KB~几 MB 的 SDK）
+ (nullable MFModuleInfo *)mainModuleForPid:(pid_t)pid
                                      error:(NSString *_Nullable *_Nullable)error;

/// 一步到位：按进程名找 pid + 取主模块基址
+ (nullable MFModuleInfo *)locateProcess:(NSString *)processName
                                   error:(NSString *_Nullable *_Nullable)error;

/// 诊断：为最近一次查找生成可读报告（含走了哪条路、匹配依据、候选列表）
+ (NSString *)lastReport;

@end

NS_ASSUME_NONNULL_END
