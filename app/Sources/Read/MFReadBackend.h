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
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 门条件（对齐原实现 sub_10099A034）：
///   模式标记 == 1 且 端口 != 0 才算"权限已就绪"
@interface MFReadBackend : NSObject

+ (instancetype)shared;

#pragma mark 门条件

/// 目标进程 task port（≡ 原 dword_100FF7470）
@property (nonatomic, assign) uint32_t targetTaskPort;

/// 模式标记（≡ 原 qword_100FF7468）
@property (nonatomic, assign) BOOL modeFlag;

/// 门判：modeFlag && 端口有效
@property (nonatomic, readonly) BOOL gateOpen;

/// 统计
@property (nonatomic, readonly) uint64_t readCount;
@property (nonatomic, readonly) uint64_t failCount;

#pragma mark 底层读取

/// 核心：读远程内存。返回 YES 表示成功
- (BOOL)readRemote:(uint64_t)remote into:(void *)out size:(size_t)size;

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
