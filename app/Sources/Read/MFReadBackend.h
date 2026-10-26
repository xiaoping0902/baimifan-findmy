//
//  MFReadBackend.h — 跨进程内存读取后端
//
//  实现依据《读取与绘制_实现全解.md》§2 + 《KFD到读取后端_完整链路报告.md》§七：
//
//  原实现（0x1009D025C，2284 字节）：
//      ├ 取 remap 指针：全局 0x100FF7520 ← dlsym("mach_vm_remap")
//      ├ 取目标端口：  全局 0x100FF7470 ← 缓存的目标 task port
//      ├ 取页大小：    全局 0x100FC78B8 ← getpagesize()
//      ├ 页对齐：      aligned = remote & -pagesize；offset = remote - aligned
//      ├ mach_vm_remap(target=self, source_task=缓存端口, source_address=aligned,
//      │               size=pagesize, mask=0, flags=VM_FLAGS_ANYWHERE,
//      │               copy=1, inheritance=VM_INHERIT_NONE)
//      ├ memcpy(local_buffer, local_mapping + offset, requested_size)
//      └ mach_vm_deallocate(self, local_mapping, pagesize)
//
//  ★ 关键设计（对齐原实现）：
//    · 每要一个字段就映射一页、只抠那几个字节、立刻解除映射（不 dump 大块）
//    · 读失败返回 0，不崩不抛 —— 这是它能长时间稳定挂着的原因
//
//  ★ [M5.207] 端口路已整体移除。原实现的 mach_vm_remap + target task port
//    在这里只是为了读内存，而我们已经有 KFD 页表直读（mfpt_*）。保留端口路
//    的唯一代价是：必须先在目标进程上 task_for_pid（并为此改 csflags），
//    等于在游戏进程里留下被持有的 task port 与被改过的签名标志。
//    现在读取只走 KFD：pid → pmap 根表 → 目标页表，不碰任何 mach 端口。
//    targetTaskPort 仅作为旧接口占位保留，恒为 MACH_PORT_NULL，不参与门判。
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 门条件：模式标记 == 1 且 KFD pmap 根表已就位
@interface MFReadBackend : NSObject

+ (instancetype)shared;

#pragma mark 门条件

/// 旧实现的端口槽位。**不再使用**：恒为 MACH_PORT_NULL。
/// 保留只为让旧调用点（快照 JSON / 诊断文本）不必改结构。
@property (nonatomic, assign) uint32_t targetTaskPort;

/// 模式标记（≡ 原 qword_100FF7468）
@property (nonatomic, assign) BOOL modeFlag;

/// 门判：modeFlag && KFD 根表有效（端口路已移除）
@property (nonatomic, readonly) BOOL gateOpen;

/// 当前读取会话的身份串："pid|可执行路径|启动秒|启动微秒"，未绑定为 nil。
///
/// 为什么需要它：会话缓存（名字表 / 物品表 / 容器内容）原来拿 task port 当
/// 会话标识，而端口已经取消。同一 PID 被系统复用时，仅凭 pid 无法区分实例，
/// 所以这里同时带上可执行路径与进程启动时间。
@property (nonatomic, copy, readonly, nullable) NSString *sessionIdentity;

/// 会话令牌：由 sessionIdentity 与 pmap 根表混合出的 64 位值，0 表示未绑定。
///
/// 缓存只需要"是不是同一场会话"这一个判断，比字符串更省。历史上这里用的是
/// task port；端口退场后改用它，语义不变（同一进程实例 = 同一令牌）。
@property (nonatomic, readonly) uint64_t sessionToken;

/// 对局世代：世界指针（GWorld）变化时 +1，用来判定「打完了，进下一局」。
///
/// 为什么需要它：进程还是那个进程，pid/路径/启动时间全没变，但换局会把
/// UWorld / ULevel / Actors 整套换掉。任何按"进程实例"缓存的绝对地址在换局后
/// 都指向旧对象，继续用就会读到垃圾 —— 表现出来就是"第一局好好的，第二局
/// 不画了，还卡"。把世界指针变化折进会话令牌，所有按会话隔离的缓存
/// （物品表 / 装备表 / 名字表）会自动失效。
@property (nonatomic, readonly) uint64_t matchEpoch;

/// 报告当前世界指针。地址非法（0 或不在用户态窗口内）时忽略，不推进世代。
///
/// 换局瞬间 GWorld 可能短暂为 0 或半初始化，所以只有读到合法指针才比较，
/// 避免加载动画那一两秒里把缓存反复清空。
- (void)noteWorldPointer:(uint64_t)world;

/// 统计
@property (nonatomic, readonly) uint64_t readCount;
@property (nonatomic, readonly) uint64_t failCount;

#pragma mark KFD 页表直读（M5.117）

/// 目标进程 pid（0 = 未绑定 KFD 后端）
@property (nonatomic, assign) int kfdPid;

/// 目标进程的 pmap 根表（内核 VA；0 = 未绑定）
@property (nonatomic, assign) uint64_t kfdRoot;

/// 用 pid 解析目标 pmap 根表并接管读取。返回 YES 表示此后读取全走 KFD。
- (BOOL)attachKFDPid:(int)pid;

/// 解绑（目标退出 / 换目标时调用），同时作废 v2p 缓存
- (void)detachKFD;

#pragma mark 底层读取

/// 核心：读远程内存。返回 YES 表示成功
- (BOOL)readRemote:(uint64_t)remote into:(void *)out size:(size_t)size;

/// [M5.135] 宽松读：返回【实际读到的字节数】（0 = 一个都没读到）。
///
/// 给"整块指针数组"这种大读用：跨到未映射页时只丢尾巴，不整批作废。
/// 注意返回小于 size 时，后面那段内容是未初始化的 —— 调用方自己 calloc/清零。
- (size_t)readRemotePartial:(uint64_t)remote into:(void *)out size:(size_t)size;

#pragma mark 六个字节封装（已证：唯一区别是"读多少字节"）

/// 8 字节 —— 指针 / 整数。失败返回 0（对齐原 FCSEL 降级）
- (uint64_t)readU64:(uint64_t)addr;

/// 8 字节但区分失败
- (BOOL)readU64:(uint64_t)addr out:(uint64_t *)out;

/// 12 字节 —— float3（坐标）。失败返回全 0
- (BOOL)readFloat3:(uint64_t)addr out:(float *)v3;

/// 4 字节 —— 单 float（FOV）。失败返回 0.0f
- (float)readFloat:(uint64_t)addr;

/// 4 字节 int。失败返回 0
- (int32_t)readInt32:(uint64_t)addr;

/// 48 字节 —— 整个相机结构体
- (BOOL)readCameraStruct:(uint64_t)addr out:(float *)v12;

/// 沿指针链逐级解引用（每级读 8 字节），任一级失败返回 0
- (uint64_t)followChain:(uint64_t)base offsets:(NSArray<NSNumber *> *)offsets;

#pragma mark 诊断

- (NSString *)statsText;
- (void)resetStats;

@end

NS_ASSUME_NONNULL_END
