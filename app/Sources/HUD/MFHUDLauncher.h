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

@end

NS_ASSUME_NONNULL_END
