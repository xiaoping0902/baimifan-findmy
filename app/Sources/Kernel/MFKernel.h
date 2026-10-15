//
//  MFKernel.h — 内核会话
//
//  实现依据《KFD到读取后端_完整链路报告.md》《KFD侧_完整分析.md》：
//    [1] 提权 root   setgid(0)/setregid(0,0)/setuid(0)/setreuid(0,0) ×2 遍
//    [2] 内核端口    task_get_special_port(task_self, 4=TASK_KERNEL_PORT, &port)
//                    —— 全二进制唯一一处；非越狱环境返回 0
//    [3] 枚举 task   路 A（要 host_priv）：host_processor_sets → host_processor_set_priv
//                                       → processor_set_tasks
//                    路 B（免特权）：    processor_set_default → processor_set_tasks
//                    匹配：proc_pidpath + strrchr('/') + strncmp
//    [4] 端口缓存    dword_100FF7470 ← 目标 task port
//    门条件：模式标记 == 1 && 端口 != 0
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MFKernelState) {
    MFKernelStateIdle = 0,      // 未启动
    MFKernelStateRunning,       // 运行中（内核已开）
    MFKernelStateFailed,        // 失败
};

typedef NS_ENUM(NSInteger, MFEnumRoute) {
    MFEnumRouteNone = 0,
    MFEnumRouteTaskForPid = 3,  // 路 C：task_for_pid + sysctl(KERN_PROC_ALL)
                                //       靠 task_for_pid-allow entitlement，最优先
    MFEnumRoutePrivileged = 1,  // 路 A：host_processor_set_priv（要 host_priv）
    MFEnumRouteDefault = 2,     // 路 B：processor_set_default（免特权）
};

/// 一个系统进程
@interface MFProcessInfo : NSObject
@property (nonatomic, assign) int pid;
@property (nonatomic, copy) NSString *name;      // basename
@property (nonatomic, copy) NSString *path;      // 完整可执行路径
@property (nonatomic, assign) uint32_t taskPort;
@end

@interface MFKernel : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) MFKernelState state;
@property (nonatomic, readonly) BOOL isOpen;
@property (nonatomic, copy, readonly) NSString *statusText;
@property (nonatomic, copy, readonly) NSString *lastError;
@property (nonatomic, readonly) uint64_t kbase;
@property (nonatomic, readonly) uint64_t kslide;
@property (nonatomic, readonly) uint64_t puafPages;
@property (nonatomic, readonly) MFEnumRoute availableRoute;

#pragma mark 生命周期

/// 启动内核链（在后台线程跑，completion 回主线程）
- (void)startWithPuafPages:(uint64_t)pages
                completion:(void (^)(BOOL ok, NSString *message))completion;

/// 只做能力探测（不跑漏洞）：拿内核端口 + 试两条枚举路
- (void)probeCapabilitiesWithCompletion:(void (^)(NSString *report))completion;

- (void)stop;

#pragma mark 提权

/// setgid/setregid/setuid/setreuid(0) 序列，两遍（对齐原实现）
- (BOOL)gainRootWithError:(NSString *_Nullable *_Nullable)err;

/// 当前身份
- (NSString *)identityText;

#pragma mark 进程枚举

/// 当前可用的枚举路（探测结果）
- (MFEnumRoute)detectRoute;

/// 枚举全系统 task。route 传 0 = 自动选
/// ★ 审查修正（P1-2）：枚举【不再】为每个进程预取 task port ——
///   那样每次刷新会泄漏 N 个端口右，且持有别人的 task 端口会让其结构无法回收。
///   现在只返回 pid / 名字 / 路径；真正要读某个进程时调 acquireTaskPortForPid:。
- (NSArray<MFProcessInfo *> *)enumerateProcessesWithRoute:(MFEnumRoute)route
                                                    error:(NSString *_Nullable *_Nullable)err;

/**
 * 按需取一个进程的 task port。
 * @return 端口；失败返回 MACH_PORT_NULL 并填 err。
 *         调用方不用时必须 mach_port_deallocate(mach_task_self(), port)。
 */
+ (uint32_t)acquireTaskPortForPid:(int)pid error:(NSString *_Nullable *_Nullable)err;

/// 按进程名匹配（对标原实现 proc_pidpath + strrchr + strncmp 前缀匹配）
- (nullable MFProcessInfo *)findProcessNamed:(NSString *)name;

#pragma mark 诊断

/// 读回 kfd 内部的 printf 诊断日志（9 个偏移的查找过程）。
/// 失败时这是唯一能看出卡在哪一步的东西。
+ (nullable NSString *)kernelLog;

/// KFD 失败后【必须】重启 App：
///   · fd 表已被 ~10000 个 sem_open 占住，且失败路径无法安全回收
///   · 内核态可能残留未清理的 PUAF 页 —— 原地重试会 kernel panic（已实测）
/// 调用后弹确认框，用户点确定就 exit(0)。
+ (void)forceRestartWithReason:(NSString *)reason;

#pragma mark 内核读写（桥接层透传）

- (BOOL)kreadAddress:(uint64_t)kaddr into:(void *)out size:(uint64_t)size;
- (BOOL)kwriteValue:(const void *)in toAddress:(uint64_t)kaddr size:(uint64_t)size;

@end

NS_ASSUME_NONNULL_END
