//
//  MFHUDApplication.h — HUD 角色的 UIApplication 子类
//
//  ── 为什么需要它 ──
//
//  白米饭的 Info.plist 里写着：
//      <key>NSPrincipalClass</key>
//      <string>HUDMainApplication</string>
//
//  而 `UIApplicationMain(argc, argv, nil, delegateClass)` 的第三个参数为 nil 时，
//  会从 Info.plist 读 NSPrincipalClass 作为 UIApplication 的类。
//
//  更关键的是：白米饭的启动流程【不用标准 UIApplicationMain】——
//  分析报告原文（《白米饭补充分析-启动窗口与功能》§2）：
//
//      「HUD 初始化局部读取 `HUDMainApplication` 和 `HUDMainApplicationDelegate` 类，
//        并调用 `UIApplicationInstantiateSingleton`。」
//
//  ── 为什么必须绕开 UIApplicationMain ──
//
//  真机症状：HUD 子进程（pid 402）起来了，日志停在
//      「即将调用 UIApplicationMain（HUD 角色）…」
//  之后再无任何输出 —— 连 MFHUDAppDelegate 的 didFinishLaunching 第一行都没有。
//
//  原因：iOS 13+ 的 UIApplicationMain 会做 scene 协商。而 posix_spawn 出来的
//  进程不走 FrontBoard，没有 UIWindowScene —— 协商永远等不到结果，于是卡死。
//
//  `UIApplicationInstantiateSingleton` 是 UIApplication 的私有函数，
//  直接创建单例、不参与 scene 协商，所以能过。
//
#import <UIKit/UIKit.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

@interface MFHUDApplication : UIApplication
@end

/// HUD 角色的完整引导：实例化 App → 设 delegate → 手动触发 didFinishLaunching → 跑 runloop
/// 返回进程退出码。
int MFLaunchHUDRole(int argc, char *argv[]);

/*
 * [M5.20] 把 UIWindow / CAContext / 托管类的真实私有方法名 dump 进日志。
 *
 * 起因：M5.19 日志显示我猜的 8 个 setter 里只有 1 个存在，
 * 说明名字猜错了。继续猜没意义，让运行时自己报出来。
 */
void MFDumpWindowAPI(void);

NS_ASSUME_NONNULL_END
