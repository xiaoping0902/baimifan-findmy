//
//  MFCalibrate.h —— KFD 页表直读 · 偏移校准（跑在 App 内部，不用 frida）
//
//  为什么放在 App 里做：
//    · 可以直接访问 MFKernelBridge.m 内部的 static struct kfd* g_kfd
//      —— 完全不需要"扫内存找句柄"（那条路曾把用户地址当 kaddr 送进内核，导致 panic）
//    · 所有内核读都能在 C 里逐个加「内核地址域」校验
//    · 结束时必定 mf_kclose()，不留悬空页
//
//  产物：一段人类可读报告 + 一份 JSON 落盘，供外部读取
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跑一次校准：反推 proc->task、vm_map->pmap、pmap 根页表字段
/// @param jsonPath 结果落盘路径（传 nil 则不写文件）
/// @return 人类可读报告；失败时也返回报告（里面写明卡在哪一步）
NSString *MFCalibrateRun(NSString *_Nullable jsonPath);

NS_ASSUME_NONNULL_END
