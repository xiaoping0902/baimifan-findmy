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
#include <stdlib.h>
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

static uint64_t g_xp_last_base;
static int      g_xp_last_pid;

uint64_t MFCrossProcLastModuleBase(void) { return g_xp_last_base; }
int      MFCrossProcLastPid(void)        { return g_xp_last_pid; }

NSString *MFCrossProcRun(int pid)
{
    NSMutableString *log = [NSMutableString string];
    uint64_t proc = 0, task = 0, map = 0, pmap = 0, root = 0;
    char why[256] = {0};
    int rc = 0;

    /* ---------- 1) 会话：必须由用户先点「启动内核」 ---------- */
    if (!mf_is_open()) {
        /*
         * ★ [M5.119] 这里不再自己 kopen。
         *
         * 用户的语义很清楚：先点「启动内核」，内核起来了才去找进程；
         * 没点内核就什么都不该动。之前自动 kopen 带来两个副作用：
         *   · 失败了会在不同时机反复开，把 PUAF 页养脏（14:07 两次 panic 的成因）
         *   · 用户看到"没点内核它也在动"，行为不可预期
         * 现在：没有内核 = 直接返回一句提示，一次系统调用都不发。
         */
        [log appendString:@"FAIL: 内核未打开 —— 先点右下角「启动内核」\n"];
        mfxp_write(log);
        return log;
    }
    mfpt_cache_reset();
    [log appendString:@"[session] 使用已打开的内核（不再自己 kopen）\n"];

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
             * ---------- 4) 游戏读取链第一跳：候选偏移全部实测 ----------
             *
             * M5.119 实测：*(base+0x15947E70) = 0x1131fb4a1，读过去是一串字符
             *     "ReturnValue\0WorldContextObject\0ObjectRegistryType\0AllObjects…"
             * 也就是说那个偏移落在【名字/反射表】里，不是 GWorld。
             *
             * 所以不再只试一个偏移：把手上所有来源的候选都读一遍，谁指向
             * UObject 形态（首 8 字节是指向模块/共享缓存的函数表指针）就留谁。
             * 全部只读，不写。
             */
            g_xp_last_base = macho;
            g_xp_last_pid = pid;
            {
                struct { uint64_t off; const char *name; } cands[] = {
                    { 0x178B44E0ULL, "our-GWorld"   },   /* 本项目旧偏移表 */
                    { 0x173776C0ULL, "our-GNames"   },   /* 旧表里的 GNames 池 */
                    { 0x15947E70ULL, "ouyi-libbase" },   /* 欧易 2.0 报告里的例子 */
                };
                [log appendFormat:@"\n[game] module base = %#llx\n", (unsigned long long)macho];

                /*
                 * ★ [M5.122] 把游戏自己的段表打出来。
                 *
                 * 这一步是为了回答"base+0x178B44E0 到底在不在映像里"：
                 * Mach-O 的 vmaddr 是镜像内地址，运行期地址 = vmaddr + slide，
                 * slide = 模块基址 - 0x100000000。打印出 __DATA 的真实区间后，
                 * 候选偏移落在里面还是外面一眼就能看出来。
                 */
                {
                    const size_t kHdrLen = 16384;
                    unsigned char *hdr = (unsigned char *)malloc(kHdrLen);
                    if (hdr && mfpt_read(root, macho, hdr, kHdrLen) == 0) {
                        uint32_t ncmds = mfxp_u32(hdr + 16);
                        uint32_t o = 32;
                        uint64_t slide = macho - 0x100000000ULL;
                        [log appendString:@"[game] 段表（vmaddr 是镜像内地址，右边是运行期区间）：\n"];
                        for (uint32_t i = 0; i < ncmds && o + 72 <= kHdrLen; i++) {
                            uint32_t cmd = mfxp_u32(hdr + o);
                            uint32_t sz  = mfxp_u32(hdr + o + 4);
                            if (sz < 8 || o + sz > kHdrLen) break;
                            if (cmd == 0x19) {           /* LC_SEGMENT_64 */
                                char nm[17];
                                uint64_t vmaddr = 0, vmsize = 0;
                                memset(nm, 0, sizeof(nm));
                                memcpy(nm, hdr + o + 8, 16);
                                memcpy(&vmaddr, hdr + o + 24, 8);
                                memcpy(&vmsize, hdr + o + 32, 8);
                                int prot = (int)mfxp_u32(hdr + o + 60);
                                uint64_t rs = vmaddr + slide;
                                [log appendFormat:
                                    @"         %-16s vm=%#llx size=%#llx prot=%d → %#llx..%#llx\n",
                                 nm, (unsigned long long)vmaddr,
                                 (unsigned long long)vmsize, prot,
                                 (unsigned long long)rs,
                                 (unsigned long long)(rs + vmsize)];
                            }
                            o += sz;
                        }
                    }
                    free(hdr);
                }

                for (unsigned int i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
                    uint64_t slot = macho + cands[i].off;
                    uint64_t val = 0;
                    int r = mfpt_read(root, slot, &val, sizeof(val));

                    /*
                     * ★ [M5.122] 把页表翻译的具体错误码打出来。
                     *
                     * mfpt_read 把所有翻译失败都折叠成 -3，看不出断在哪一级。
                     * 直接调 mfpt_translate 拿原始码：
                     *   -5  L1 不合法（地址不在目标映射里）
                     *   -8  L2 不合法
                     *   -11 L3 不存在
                     *   -12 压缩页（我们的走法不覆盖）
                     *   -6/-9 ptov 查不到对应物理窗口
                     */
                    {
                        uint64_t pa = 0;
                        int tr = mfpt_translate(root, slot, &pa);
                        [log appendFormat:
                            @"[game]   translate(%#llx) rc=%d pa=%#llx %@\n",
                         (unsigned long long)slot, tr, (unsigned long long)pa,
                         tr == 0 ? @"(映射存在)"
                                 : (tr == -11 ? @"(L3 不存在 = 这页没映射)"
                                              : (tr == -12 ? @"(压缩页)" : @"(其它)"))];
                    }

                    BOOL plausible = (r == 0 && val > 0x100000000ULL && val < 0x8000000000ULL);

                    [log appendFormat:@"[game] %-13s base+%#-10llx = %#llx (rc=%d)%@\n",
                     cands[i].name, (unsigned long long)cands[i].off,
                     (unsigned long long)val, r,
                     plausible ? @"  ← 用户态指针" : @"  (非指针)"];
                    if (!plausible) {
                        continue;
                    }

                    uint64_t dump[8] = {0};
                    if (mfpt_read(root, val, dump, sizeof(dump)) != 0) {
                        [log appendString:@"         (指向的内存不可读)\n"];
                        continue;
                    }
                    /* 顺手把前 16 字节当 ASCII 打出来：名字池会直接露馅 */
                    char ascii[17] = {0};
                    memcpy(ascii, dump, 16);
                    for (int k = 0; k < 16; k++) {
                        if (ascii[k] < 0x20 || ascii[k] > 0x7e) ascii[k] = '.';
                    }
                    [log appendFormat:@"         +00=%#llx +08=%#llx  ascii=\"%s\"\n",
                     (unsigned long long)dump[0], (unsigned long long)dump[1], ascii];
                }
            }
        }
    }

done:
    /*
     * [M5.119] 会话归用户管：这里不 kclose。
     * 关会话的时机只有两个 —— 用户点「关闭内核」，或离开进程页（viewWillDisappear）。
     * 这样既符合"点了内核才找进程"，也不会在页面外留着悬空页。
     */
    {
        uint64_t cacheHit = 0, cacheMiss = 0;
        mfpt_cache_stats(&cacheHit, &cacheMiss);
        [log appendFormat:@"[cache] v2p 命中=%llu 未命中=%llu\n",
         (unsigned long long)cacheHit, (unsigned long long)cacheMiss];
    }
    mfxp_write(log);
    return log;
}
