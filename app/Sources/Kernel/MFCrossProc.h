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

#ifdef __cplusplus
}
#endif

#endif /* MF_CROSS_PROC_H */
