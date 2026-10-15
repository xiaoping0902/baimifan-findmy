/*
 * MFHUDLog —— HUD 侧的文件日志
 *
 * 为什么不用 NSLog：
 *   HUD 是 posix_spawn 出来的独立进程。它到底有没有跑到建窗那一步，
 *   只看屏幕看不出来（窗口可能建了但没进合成器）。而 syslog 这条路
 *   受两个因素影响：
 *     · mf_redirect_klog() 会 dup2 掉 fd 1/2，而 posix_spawn 没传
 *       file_actions → 子进程 100% 继承父进程的 fd（桥接层注释已确认）
 *     · HUD 子进程在「启动内核」之前就被拉起，那时还没重定向
 *   所以最可靠的证据是【自己写文件】。
 *
 * 主进程可以复用 mf_read_klog() 那套读取逻辑回显（同一沙盒 Documents）。
 *
 * 记录的关键量（HUD 审查报告 §4.1 指定）：
 *     windowScene / _contextId / hidden / applicationState
 * 三者任一异常（scene 为 nil、状态是 Background、contextId 为 0），
 * 就能把「窗口建了但没进合成器」从推断提升为定案。
 */

#ifndef MFHUDLog_h
#define MFHUDLog_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 追加一行到沙盒 Documents/mf_hud.log（自动加时间戳）。从任意线程可调。
void MFHUDLogLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 读回整个 HUD 日志。返回 malloc 的字符串，调用方 free；没有则 NULL。
char *MFHUDLogRead(void);

/// 清空 HUD 日志
void MFHUDLogClear(void);

#ifdef __cplusplus
}
#endif

#endif /* MFHUDLog_h */
