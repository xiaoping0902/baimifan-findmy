//
//  MFDebugExport.h — 把诊断数据镜像到 AFC 够得着的地方
//
//  ── 为什么需要它 ──
//
//  调试链路里最别扭的一环是【把数据从 iPad 弄到 Windows】。
//
//  · AFC（pymobiledevice3 唯一能直接读的通道）只暴露 /var/mobile/Media
//  · 我们的 App 沙盒在 /var/mobile/Containers/Data/Application/<UUID>/Documents
//  · 两者不通 → 之前只能靠「App 弹窗显示日志 + 用户手动复制粘贴」
//
//  但我们有 com.apple.private.security.no-sandbox（从设备读出核对过），
//  所以可以【主动】把日志/状态/截图写到 Media —— 那边 AFC 直接能拉，
//  用户侧零操作。
//
//  ── 写到哪 ──
//
//      /var/mobile/Media/mf-debug/
//        ├── kfd.log        内核链日志
//        ├── hud.log        HUD 子进程日志
//        ├── state.json     当前状态快照
//        ├── screen.png     自截图
//        └── README.txt     说明
//
//  ── Windows 侧怎么用 ──
//
//      python scripts/dev.py pull        # 一次拉全部
//      python scripts/dev.py status      # 拉完直接看摘要
//

#ifndef MFDebugExport_h
#define MFDebugExport_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AFC 能直接读到的导出目录（/var/mobile/Media/mf-debug）
extern NSString * const MFDebugExportDir;

@interface MFDebugExport : NSObject

/// 导出目录真的可写吗（首次调用会创建目录并做一次写测试）
+ (BOOL)isAvailable;

/// 上次不可用的原因；可用时为 nil
+ (nullable NSString *)lastError;

/// 把 Documents 里的日志镜像过去（kfd.log / hud.log）
+ (NSUInteger)syncLogs;

/// 写一份状态快照 state.json（设备/身份/内核/读取链/清理规则）
+ (BOOL)writeStateSnapshot;

/// 自己截自己的屏，存成 screen.png
/// 说明：DDI 挂不上时 dvt screenshot 用不了，但 App 自己可以抓自己的窗口 ——
///       至少能看到 UI 长什么样。跨 App 的画面抓不到（那需要 DDI）。
+ (BOOL)captureSelfScreenshot;

/// 一键全做：同步日志 + 状态快照 + 截图。返回可读的结果摘要。
+ (NSString *)exportAll;

/// 清掉导出目录里的所有文件
+ (BOOL)clearExports;

@end

NS_ASSUME_NONNULL_END

#endif /* MFDebugExport_h */
