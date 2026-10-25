//
//  MFCrossProc.h -- 跨进程读自检（M5.108）
//
//  pid -> proc -> proc_ro -> task -> vm_map -> pmap -> tte，然后拿目标进程的
//  页表根去读它自己的 Mach-O 头。读到 0xfeedfacf 就说明"内核页表直读"这条
//  路对别的进程也成立 —— 这是读游戏数据之前必须先过的一关。
//
#ifndef MF_CROSS_PROC_H
#define MF_CROSS_PROC_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 返回可直接显示的报告；同时写 /var/mobile/Media/mf-debug/mf-crossproc.txt。 */
NSString *MFCrossProcRun(int pid);

/*
 * [M5.119] 最近一次成功解析出来的目标模块基址 / pid。
 * 上层（模块定位 / UE4 链解析 / HUD）不用再自己扫 Mach-O，直接用这个值。
 * 返回 0 表示还没有成功过一次。
 */
uint64_t MFCrossProcLastModuleBase(void);
int      MFCrossProcLastPid(void);

#ifdef __cplusplus
}
#endif

#endif /* MF_CROSS_PROC_H */
