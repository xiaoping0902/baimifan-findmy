//
//  MFHUDLauncher.h — 派生 HUD 进程
//
//  对齐分析已证：主程序「获取自己的可执行路径，再 posix_spawn 自己」，
//  参数为 -hud / -hud1 / -hud2 / -hud3；-check 带 waitpid 状态收集。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MFHUDLauncher : NSObject

/// HUD 是否已在运行（读 PID 文件 + kill(pid,0) 探活）
+ (BOOL)isHUDRunning;
+ (pid_t)hudPID;

/// 拉起 HUD 进程
+ (BOOL)startHUDWithError:(NSString *_Nullable *_Nullable)err;

/// 结束 HUD 进程
+ (BOOL)stopHUDWithError:(NSString *_Nullable *_Nullable)err;

/// PID 文件路径
+ (NSString *)pidFilePath;

#pragma mark - [M5.26] root 助手

/*
 * 以 root 身份派生自己，附指定参数，等它结束，返回退出码。
 *
 * 为什么需要：
 *   TrollStore 装的 App 本体跑在 mobile(501)，entitlements 只对【本进程】
 *   生效，改不了自己的 uid。要让「清理系统残留 / Keychain / 防封 / 巨魔装卸」
 *   这些特权操作真正以 root 跑，必须在 posix_spawn 时就指定身份：
 *       persona 99 + uid 0 + gid 0
 *
 * 对齐 TrollSpeed（Lessica，开源，ch.xxtou.hudapp）的 HUDHelper.mm：
 *       posix_spawnattr_set_persona_np(&attr, 99, OVERRIDE);
 *       posix_spawnattr_set_persona_uid_np(&attr, 0);
 *       posix_spawnattr_set_persona_gid_np(&attr, 0);
 *       posix_spawnattr_setpgroup(&attr, 0);
 *       posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
 *
 * 依赖 entitlement：com.apple.private.persona-mgmt（已有）。
 *
 * @param args  子进程参数（不含 argv[0]），例如 @[@"-root", @"whoami"]
 * @param out   子进程的 stdout（可为 nil）
 * @return 退出码；派生失败返回 -1
 */
+ (int)runAsRootWithArgs:(NSArray<NSString *> *)args
                  output:(NSString *_Nullable *_Nullable)out;

/// 上次 root 助手是否真的拿到了 uid 0（由子进程回报，供 UI 显示）
+ (BOOL)lastRootChildWasRoot;

@end

NS_ASSUME_NONNULL_END
