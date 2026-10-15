//
//  MFHUDControl.h — 控制台 ↔ HUD 子进程的控制通道
//
//  ★ 为什么需要这个文件 ★
//
//  HUD 子进程是以 persona + uid 0（root）拉起来的（对齐 TrollSpeed），
//  而控制台是 mobile(501)。Unix 的信号权限规则是「发送者的 real/effective
//  uid 必须等于目标的 real/saved uid」——
//  也就是说 mobile 给 root 发 SIGTERM 会被内核直接拒绝：
//
//      kill(hudPID, SIGTERM) -> -1, errno = EPERM(1)
//
//  真机表现就是用户在控制台点「结束悬浮窗」永远失败，
//  菜单里也没有任何退出入口 —— HUD 起得来、退不掉。
//
//  所以退出改走两条**不需要跨 uid 权限**的通道：
//
//    ① Darwin notification（notifyd 全局命名空间，任何 uid 都能 post/observe）
//    ② PID 文件看门狗（文件系统本来就跨 uid 共享）
//
//  加上这两条之后，退出由 HUD **自己**执行 —— 自己杀自己不需要任何权限。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 控制台 post、HUD 监听。名字固定，两端必须一致。
extern NSString *const MFHUDExitNotificationName;

/// HUD 子进程的 PID 文件。控制台写/删，HUD 用它做看门狗兜底。
/// 原版白米饭用 /var/mobile/Library/Caches/ch.xxtou.hudapp.pid，
/// 这里换成自己的名字，避免与真白米饭冲突。
extern NSString *const MFHUDPIDFilePath;

@interface MFHUDControl : NSObject

/// 控制台侧：请求「当前那个 HUD 进程」退出。不返回是否成功 ——
/// 调用方应该用 MFHUDLauncher 的探活轮询来确认结局。
+ (void)requestExit;

/// HUD 侧：收到退出请求（通知或看门狗）时执行一次 handler。
/// handler 只会在主线程被调用一次。
+ (void)watchForExitRequest:(dispatch_block_t)handler;

/// HUD 侧：撤销监听（正常路径不会用到，留给失败清理）。
+ (void)stopWatching;

/// 仅供测试/诊断：看门狗是否已经确认过「PID 文件里的 pid 就是我」。
+ (BOOL)watchdogSawOwnPID;

@end

NS_ASSUME_NONNULL_END
