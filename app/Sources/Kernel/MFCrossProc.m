//
//  MFCrossProc.m -- 用 KFD 的页表直读去读【别的进程】的内存（M5.108）
//
//  链路（每一跳都在本进程上验证过，见 MFCalibrate / MFKernelBridge）：
//      pid --allproc--> proc --[+0x18]--> proc_ro --[+0x08]--> task
//           --[+0x28]--> vm_map --[+0x40]--> pmap --[+0x00]--> tte(根表)
//
//  验证办法：目标进程的 Mach-O 头必须读回 0xfeedfacf。
//  定位办法：从 VA 0x100000000 起，用目标自己的 L1/L2/L3 页表找"最低的一个
//  已映射页"—— iOS 主可执行文件的 __PAGEZERO 占掉低 4 GB，所以这个页就是
//  主二进制的 __TEXT 起点。全程只读页表描述符与已映射页，不碰未知地址。
//
//  会话管理：这个函数是【一次性探针】。校准结束时已经 kclose 过，所以这里
//  如果发现内核没打开，就自己 kopen 一次，做完再 kclose —— 和校准同一套
//  生命周期，不在进程里留悬空页。
//
#import "MFCrossProc.h"
#import "MFKernelBridge.h"
#import "MFPageTable.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>   /* usleep：physpuppet 重试间隔 */

#define MF_XP_SCAN_START  0x100000000ULL
#define MF_XP_PAGE        0x4000ULL
#define MF_XP_SCAN_PAGES  96

static NSString * const kMFXPText = @"/var/mobile/Media/mf-debug/mf-crossproc.txt";

static void mfxp_write(NSString *text)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:@"/var/mobile/Media/mf-debug"
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];
    [text writeToFile:kMFXPText atomically:YES
             encoding:NSUTF8StringEncoding error:NULL];
}

static uint32_t mfxp_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

NSString *MFCrossProcRun(int pid)
{
    NSMutableString *log = [NSMutableString string];
    BOOL ownSession = NO;
    uint64_t proc = 0, task = 0, map = 0, pmap = 0, root = 0;
    char why[256] = {0};
    int rc = 0;

    /* ---------- 1) 会话 ---------- */
    if (!mf_is_open()) {
        /*
         * ★ [M5.113] 不能再用 mf_kopen_default()：它的默认值是
         * landa + 3072（按 16.6.1 写的），在 16.1 上直接
         * `assertion failed: (false) at krkw.h:412`。
         * 这里显式用真机验证过的 physpuppet + 1024 + sem_open(1/1)。
         *
         * ★ [M5.116] 不再连试 3 次。
         *
         * M5.114 加过"失败隔 300 ms 重试 3 次"，本意是绕过 physpuppet 的
         * 概率性失败。但真机证据表明：失败一次之后 perfmon 就已经锁住了
         * （后续报 physpuppet.h:113 / "已上锁"），再接二连三地 kopen 只会
         * 把 PUAF 页养脏，最后以
         *     pmap_mark_page_as_ppl_page_internal: page still has mappings
         * 整机 panic 收场（14:07:22、14:07:59 两次都是）。
         *
         * 所以：一次机会。失败就如实报错，并明确告诉用户"重启 App 再来"。
         */
        int krc = mf_kopen(1024, MF_PUAF_PHYSPUPPET,
                           MF_KREAD_SEM_OPEN, MF_KWRITE_SEM_OPEN);
        if (krc != 0) {
            const char *e = mf_last_error();
            NSString *errStr = (e && e[0]) ? [NSString stringWithUTF8String:e] : @"(no detail)";
            [log appendFormat:
                @"FAIL: 自动 kopen(physpuppet/1024) 失败 (rc=%d)\n  %@\n"
                @"  → 这一次的 perfmon 已经脏了，不要再连点；\n"
                @"    上滑杀掉 App 重开（或重启设备）后再试。\n",
             krc, errStr ?: @"(undecodable)"];
            mfxp_write(log);
            return log;
        }
        ownSession = YES;
        [log appendString:@"[session] 自己 kopen 成功（physpuppet/1024，一次过）\n"];
    } else {
        [log appendString:@"[session] 复用已打开的内核\n"];
    }

    mfpt_stats_reset();

    /* ---------- 2) 地址链 ---------- */
    rc = mf_pid_chain(pid, &proc, &task, &map, &pmap, &root, why, sizeof(why));
    /*
     * ★ [M5.111] 这里原来用 %s 直接塞 why —— NSString 的 %s 是按系统编码解释
     * 的，中文会被二次编码成 "Ê≤°ËÉΩ…"，AFC 拉回来根本没法读。
     * 必须先转成 NSString 再用 %@。
     */
    {
        NSString *whyStr = (why[0] != '\0') ? [NSString stringWithUTF8String:why] : @"(no detail)";
        [log appendFormat:@"[chain] pid=%d rc=%d\n  %@\n", pid, rc, whyStr ?: @"(undecodable)"];
    }
    if (rc != 0) {
        [log appendString:@"\nFAIL: 地址链没走通（见上一行原因）\n"];
        goto done;
    }

    /* ---------- 3) 找目标的最低映射页 ---------- */
    {
        uint64_t base = 0;
        int lrc = mfpt_lowest_mapped_page(root, MF_XP_SCAN_START, &base);
        [log appendFormat:@"[scan] lowest mapped page >= %#llx -> %#llx (rc=%d)\n",
         (unsigned long long)MF_XP_SCAN_START, (unsigned long long)base, lrc];

        uint32_t magic = 0;
        uint64_t macho = 0;
        if (lrc == 0 && base != 0) {
            for (uint32_t i = 0; i < MF_XP_SCAN_PAGES; i++) {
                uint64_t cand = base + (uint64_t)i * MF_XP_PAGE;
                uint32_t v = 0;
                if (mfpt_probe32(root, cand, &v) == 0 && v == 0xfeedfacfU) {
                    macho = cand;
                    magic = v;
                    break;
                }
            }
        }

        uint64_t ok = 0, bad = 0;
        mfpt_stats(&ok, &bad);

        if (macho == 0) {
            [log appendFormat:@"[read] 前 %u 页里没有 0xfeedfacf\n"
                               @"[stat] 页翻译成功=%llu 失败=%llu\n"
                               @"\nFAIL: 目标地址空间读不到 Mach-O 头\n",
             (unsigned)MF_XP_SCAN_PAGES, (unsigned long long)ok, (unsigned long long)bad];
            goto done;
        }

        {
            uint8_t hdr[32] = {0};
            int hrc = mfpt_read(root, macho, hdr, sizeof(hdr));
            uint32_t cputype = 0, cpusub = 0, filetype = 0, ncmds = 0, sizeofcmds = 0;
            if (hrc == 0) {
                cputype    = mfxp_u32(hdr + 4);
                cpusub     = mfxp_u32(hdr + 8);
                filetype   = mfxp_u32(hdr + 12);
                ncmds      = mfxp_u32(hdr + 16);
                sizeofcmds = mfxp_u32(hdr + 20);
            }

            [log appendFormat:
                @"[read] %#llx magic=%#x cputype=%#x cpusub=%#x filetype=%u ncmds=%u sizeofcmds=%u (rc=%d)\n"
                @"[stat] 页翻译成功=%llu 失败=%llu\n"
                @"\nRESULT OK —— 跨进程页表直读成立\n"
                @"  pid=%d  proc=%#llx  task=%#llx\n"
                @"  map=%#llx  pmap=%#llx  root=%#llx\n"
                @"  目标 Mach-O @ %#llx，头 4 字节 0xfeedfacf\n",
             (unsigned long long)macho, magic, cputype, cpusub, filetype, ncmds, sizeofcmds, hrc,
             (unsigned long long)ok, (unsigned long long)bad,
             pid, (unsigned long long)proc, (unsigned long long)task,
             (unsigned long long)map, (unsigned long long)pmap, (unsigned long long)root,
             (unsigned long long)macho];

            /*
             * ---------- 4) 游戏读取链第一跳：模块基址 + GWorld ----------
             *
             * 偏移取自同类产品的逆向结论（欧易 2.0：GWorld 指针存在
             * libbase+0x15947E70）。这里只做"能不能读出像样的指针"的探测，
             * 读不到就如实报，不做任何写操作。
             */
            {
                const uint64_t gwSlot = 0x15947E70ULL;
                uint64_t gw = 0;
                int grc = mfpt_read(root, macho + gwSlot, &gw, sizeof(gw));
                BOOL plausible = (grc == 0 && gw > 0x100000000ULL && gw < 0x8000000000ULL);

                [log appendFormat:
                    @"\n[game] module base            = %#llx\n"
                    @"[game] *(base + %#llx)  = %#llx (rc=%d) %@\n",
                 (unsigned long long)macho, (unsigned long long)gwSlot,
                 (unsigned long long)gw, grc,
                 plausible ? @"→ 像是个用户态指针" : @"→ 不是合法用户指针"];

                if (plausible) {
                    uint64_t dump[8] = {0};
                    if (mfpt_read(root, gw, dump, sizeof(dump)) == 0) {
                        [log appendString:@"[game] 该指针指向的前 8 个 qword：\n"];
                        for (int i = 0; i < 8; i++) {
                            [log appendFormat:@"     +%02X: %#llx\n", i * 8,
                             (unsigned long long)dump[i]];
                        }
                    } else {
                        [log appendString:@"[game] 该指针指向的内存不可读\n"];
                    }
                }
            }
        }
    }

done:
    if (ownSession) {
        mf_kclose();
        [log appendString:@"[session] 已 kclose（不留悬空页）\n"];
    }
    {
        uint64_t cacheHit = 0, cacheMiss = 0;
        mfpt_cache_stats(&cacheHit, &cacheMiss);
        [log appendFormat:@"[cache] v2p 命中=%llu 未命中=%llu\n",
         (unsigned long long)cacheHit, (unsigned long long)cacheMiss];
    }
    mfxp_write(log);
    return log;
}
