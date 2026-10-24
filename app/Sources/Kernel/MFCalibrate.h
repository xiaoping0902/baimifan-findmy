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

/*
 * 必须写 extern "C"：
 *   调用方 MFProcessViewController.mm 是 Objective-C++（.mm），会把函数名按
 *   C++ 规则 mangle；实现 MFCalibrate.m 是纯 ObjC，导出的是 C 符号
 *   _MFCalibrateRun。不加这层，链接期报：
 *     "MFCalibrateRun(NSString*)", referenced from: …
 *     NOTE: found '_MFCalibrateRun' in MFCalibrate.o,
 *           declaration possibly missing 'extern "C"'
 *   这是构建 #ipa-99 实际踩过的。
 */
#ifdef __cplusplus
extern "C" {
#endif

/// 跑一次校准：反推 proc->task、vm_map->pmap、pmap 根页表字段
/// @param jsonPath 结果落盘路径（传 nil 则不写文件）
/// @return 人类可读报告；失败时也返回报告（里面写明卡在哪一步）
NSString *MFCalibrateRun(NSString *_Nullable jsonPath);

/*
 * [M5.115] 校准结束后要不要把内核会话关掉。
 *
 * 默认 NO：校准是一次性诊断，关掉不留悬空页。
 * 但"启动内核 → 自动找进程 → 读内存"这条主线上，内核必须一直开着 ——
 * 否则每次读都要重新 kopen（而 kopen 是概率性的，多开一次就多一次失败/脏页）。
 * 进程页在启动内核后调一次 MFCalibrateSetKeepKernel(YES)，让会话留到
 * 用户主动点「关闭内核」为止。
 *
 * 注意：会话开着的时候【不要上滑强杀 App】——那会让 perfmon 脏掉，只能重启设备。
 */
void MFCalibrateSetKeepKernel(BOOL keep);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
