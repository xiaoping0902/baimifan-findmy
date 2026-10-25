//
//  MFPageTable.m -- 3-level 16 KB page-table walk, ptov-aware
//
//  Proven on device by M5.107 (see MFCalibrate.m for the instrument that
//  established it):
//      pmap->tte (offset 0) is the root; 3 levels; mask 0x0000FFFFFFFFC000;
//      PA -> KVA must go through ptov_table first, otherwise every child table
//      lands in the wrong window and the descriptors read as garbage.
//
//  Reads go through mf_kread32 only, so the kernel VA guard in MFKernelBridge
//  still applies to every access.
//
#import "MFPageTable.h"
#import "MFKernelBridge.h"

#include <string.h>
#include <stdio.h>
#include <time.h>      /* clock_gettime —— v2p 缓存 TTL */

#define MFP_KADDR_MIN   0xffff000000000000ULL
#define MFP_MASK_16K    0x0000ffffffffc000ULL

#define MFP_TTE_VALID       0x1ULL
#define MFP_TTE_TYPE_MASK   0x2ULL
#define MFP_PTE_TYPE_VALID  0x3ULL
#define MFP_PTE_COMPRESSED  0x8000000000000000ULL
#define MFP_PTE_COMP_ALT    0x4000000000000000ULL

#define MFP_L1_OFFMASK  0x0000000fffffffffULL
#define MFP_L1_INDEX    0x00007ff000000000ULL
#define MFP_L2_OFFMASK  0x0000000001ffffffULL
#define MFP_L2_INDEX    0x0000000ffe000000ULL
#define MFP_L3_OFFMASK  0x0000000000003fffULL
#define MFP_L3_INDEX    0x0000000001ffc000ULL

#define MFP_L1_SHIFT  36ULL
#define MFP_L2_SHIFT  25ULL
#define MFP_L3_SHIFT  14ULL

#define MFP_PAGE_SIZE 0x4000ULL
#define MFP_PAGE_OFF(v) ((uint64_t)(v) & (MFP_PAGE_SIZE - 1ULL))

static uint64_t g_mfpt_translated;
static uint64_t g_mfpt_failed;

void mfpt_stats(uint64_t *translated, uint64_t *failed)
{
    if (translated) *translated = g_mfpt_translated;
    if (failed) *failed = g_mfpt_failed;
}

void mfpt_stats_reset(void)
{
    g_mfpt_translated = 0;
    g_mfpt_failed = 0;
}

static int mfp_is_kaddr(uint64_t a)
{
    return a >= MFP_KADDR_MIN;
}

static int mfp_k32(uint64_t a, uint32_t *out)
{
    if (!out || !mfp_is_kaddr(a)) return -1;
    return mf_kread32(a, out);
}

static int mfp_k64(uint64_t a, uint64_t *out)
{
    uint32_t lo = 0, hi = 0;
    if (!out || !mfp_is_kaddr(a)) return -1;
    if (mfp_k32(a, &lo) != 0) return -1;
    if (mfp_k32(a + 4, &hi) != 0) return -1;
    *out = ((uint64_t)hi << 32) | lo;
    return 0;
}

/* ptov_table first, then the main physmap: identical to libkfd's phystokv. */
static int mfp_phys_to_kva(uint64_t pa, uint64_t *kva)
{
    uint64_t v = mf_phys_to_kv(pa);
    if (v == 0 || !mfp_is_kaddr(v)) return -1;
    *kva = v;
    return 0;
}

/*
 * [M5.117] v2p 页缓存。
 *
 * 实测口径（与欧易 2.0 的 g_v2p_cache 同一思路）：一次翻译 = 3 次 kread，
 * 而 sem_open 每次只保证 4 字节。若每帧读几十个字段、每个字段都从头走页表，
 * 内核读写次数会爆炸 —— 这是"看起来能读、一上绘制就卡死"的直接原因。
 *
 * 结构：4096 项直接映射，键 = (root, 页号)，值 = 物理页基址。
 *   · 同一 root 命中直接返回，不再碰内核；
 *   · root 变化（换进程/游戏重启换了 pmap）→ 整表作废，避免读到旧页表；
 *   · 命中率极高：游戏对象基本都落在少数几个页里。
 */
#define MFP_V2P_SLOTS 4096

typedef struct {
    uint64_t root;      /* 0 = 空槽 */
    uint64_t vpage;     /* va & ~0x3fff */
    uint64_t pbase;     /* 物理页基址 */
    uint32_t stamp;     /* [M5.135] 填充时刻（秒）；0 = 空槽 */
} mfp_v2p_entry;

/*
 * [M5.135] 缓存 TTL。
 *
 * 原来条目只要 root 不变就永久有效 —— 但游戏会释放/重映射页面（关卡切换、
 * 对象销毁）。页面被回收之后，旧条目仍会把 VA 翻到【那块物理页现在的住户】上，
 * 读出来的就是别人的数据：幽灵框、位置乱跳，而且不报错。
 *
 * 给每条加一个时间戳，超过 TTL 就当未命中重新走页表。3 秒是折中：
 * 一次遍历 3 次 kread，重走代价可接受；同时把"读到已回收页面"的窗口压到 3 秒内。
 */
#define MFP_V2P_TTL_SECONDS 3

static uint32_t mfp_now_seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint32_t)ts.tv_sec;
}

static mfp_v2p_entry g_v2p[MFP_V2P_SLOTS];
static uint64_t g_v2p_root;
static uint64_t g_v2p_hit;
static uint64_t g_v2p_miss;

static uint32_t mfp_v2p_slot(uint64_t root, uint64_t vpage)
{
    uint64_t h = (root >> 12) ^ (vpage >> 14);
    h ^= h >> 17;
    h *= 0x9E3779B97F4A7C15ULL;
    return (uint32_t)(h >> 40) & (MFP_V2P_SLOTS - 1);
}

static void mfp_v2p_reset(uint64_t root)
{
    memset(g_v2p, 0, sizeof(g_v2p));
    g_v2p_root = root;
    g_v2p_hit = 0;
    g_v2p_miss = 0;
}

void mfpt_cache_stats(uint64_t *hit, uint64_t *miss)
{
    if (hit) *hit = g_v2p_hit;
    if (miss) *miss = g_v2p_miss;
}

void mfpt_cache_reset(void)
{
    mfp_v2p_reset(0);
}

static int mfpt_translate_locked(uint64_t root, uint64_t va, uint64_t *pa)
{
    uint64_t tt = root;
    uint64_t tte = 0;
    uint64_t idx;

    if (!pa) return -2;
    *pa = 0;
    if (!mfp_is_kaddr(root)) return -3;

    /* ---- 缓存命中：省掉整条页表遍历 ---- */
    if (root != g_v2p_root) {
        mfp_v2p_reset(root);
    }
    {
        uint64_t vpage = va & ~(MFP_PAGE_SIZE - 1ULL);
        uint32_t slot = mfp_v2p_slot(root, vpage);
        uint32_t now = mfp_now_seconds();
        int fresh = (g_v2p[slot].stamp != 0 &&
                     (uint32_t)(now - g_v2p[slot].stamp) <= MFP_V2P_TTL_SECONDS);
        if (g_v2p[slot].root == root && g_v2p[slot].vpage == vpage && fresh) {
            g_v2p_hit++;
            *pa = g_v2p[slot].pbase + (va & (MFP_PAGE_SIZE - 1ULL));
            return 0;
        }
        g_v2p_miss++;
    }

    idx = (va & MFP_L1_INDEX) >> MFP_L1_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) return -4;
    if ((tte & MFP_TTE_VALID) != MFP_TTE_VALID) return -5;
    if ((tte & MFP_TTE_TYPE_MASK) == 0) {
        *pa = ((tte & MFP_MASK_16K & ~MFP_L1_OFFMASK) | (va & MFP_L1_OFFMASK));
        return 0;
    }
    if (mfp_phys_to_kva(tte & MFP_MASK_16K, &tt) != 0) return -6;

    idx = (va & MFP_L2_INDEX) >> MFP_L2_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) return -7;
    if ((tte & MFP_TTE_VALID) != MFP_TTE_VALID) return -8;
    if ((tte & MFP_TTE_TYPE_MASK) == 0) {
        *pa = ((tte & MFP_MASK_16K & ~MFP_L2_OFFMASK) | (va & MFP_L2_OFFMASK));
        return 0;
    }
    if (mfp_phys_to_kva(tte & MFP_MASK_16K, &tt) != 0) return -9;

    idx = (va & MFP_L3_INDEX) >> MFP_L3_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) return -10;
    if ((tte & MFP_PTE_TYPE_VALID) != MFP_PTE_TYPE_VALID) return -11;
    if (tte & (MFP_PTE_COMPRESSED | MFP_PTE_COMP_ALT)) return -12;

    {
        uint64_t pbase = tte & MFP_MASK_16K;
        uint64_t vpage = va & ~(MFP_PAGE_SIZE - 1ULL);
        uint32_t slot = mfp_v2p_slot(root, vpage);
        g_v2p[slot].root = root;
        g_v2p[slot].vpage = vpage;
        g_v2p[slot].pbase = pbase;
        g_v2p[slot].stamp = mfp_now_seconds();
        *pa = pbase | (va & MFP_L3_OFFMASK);
    }
    return 0;
}

/*
 * [M5.123] 把三级走法的每一步原样打出来。
 *
 * 起因：Frida 在游戏自己地址空间里读 base+0x178B44E0 是成功的（拿到
 * 0x13d302600），而我们的 walk 报 -11（L3 不存在）。同一个 root 读
 * __TEXT 又是成功的。也就是说判据在特定页上不成立，必须看原始描述符。
 *
 * 输出每一级的下标、表地址、描述符原值、以及 VALID/TYPE 两位的解读。
 * 返回 walk 的最终结果码（0 表示成功）。
 */
int mfpt_walk_trace(uint64_t root, uint64_t va, char *buf, size_t cap)
{
    size_t used = 0;
    uint64_t tt = root, tte = 0, idx, pa = 0;
    int rc = 0;
    size_t n;

#define MFP_EMIT(...)                                                      \
    do {                                                                   \
        if (used + 1 < cap) {                                              \
            n = (size_t)snprintf(buf + used, cap - used, __VA_ARGS__);      \
            if (n > 0) used += (n < cap - used ? n : cap - used - 1);        \
        }                                                                  \
    } while (0)

    if (!buf || cap == 0) return -2;
    buf[0] = '\0';

    MFP_EMIT("    walk va=%#llx root=%#llx\n", (unsigned long long)va,
             (unsigned long long)root);

    idx = (va & MFP_L1_INDEX) >> MFP_L1_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) {
        MFP_EMIT("      L1[%llu] %#llx 读失败\n", (unsigned long long)idx,
                 (unsigned long long)(tt + idx * 8));
        return -4;
    }
    MFP_EMIT("      L1[%llu] %#llx = %#llx  v=%d t=%d%s\n",
             (unsigned long long)idx, (unsigned long long)(tt + idx * 8),
             (unsigned long long)tte, (int)(tte & 1), (int)((tte >> 1) & 1),
             ((tte & 1) && !((tte >> 1) & 1)) ? "  (块描述符)" : "");
    if (!(tte & MFP_TTE_VALID)) return -5;
    if (!((tte >> 1) & 1)) {                       /* L1 block: 512 GB */
        pa = ((tte & MFP_MASK_16K & ~MFP_L1_OFFMASK) | (va & MFP_L1_OFFMASK));
        MFP_EMIT("      → L1 块映射 pa=%#llx\n", (unsigned long long)pa);
        return 0;
    }
    if (mfp_phys_to_kva(tte & MFP_MASK_16K, &tt) != 0) return -6;

    idx = (va & MFP_L2_INDEX) >> MFP_L2_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) {
        MFP_EMIT("      L2[%llu] 读失败\n", (unsigned long long)idx);
        return -7;
    }
    MFP_EMIT("      L2[%llu] %#llx = %#llx  v=%d t=%d%s\n",
             (unsigned long long)idx, (unsigned long long)(tt + idx * 8),
             (unsigned long long)tte, (int)(tte & 1), (int)((tte >> 1) & 1),
             ((tte & 1) && !((tte >> 1) & 1)) ? "  (块描述符)" : "");
    if (!(tte & MFP_TTE_VALID)) return -8;
    if (!((tte >> 1) & 1)) {                       /* L2 block: 32 MB */
        pa = ((tte & MFP_MASK_16K & ~MFP_L2_OFFMASK) | (va & MFP_L2_OFFMASK));
        MFP_EMIT("      → L2 块映射 pa=%#llx\n", (unsigned long long)pa);
        return 0;
    }
    if (mfp_phys_to_kva(tte & MFP_MASK_16K, &tt) != 0) return -9;

    idx = (va & MFP_L3_INDEX) >> MFP_L3_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) {
        MFP_EMIT("      L3[%llu] 读失败\n", (unsigned long long)idx);
        return -10;
    }
    MFP_EMIT("      L3[%llu] %#llx = %#llx  v=%d t=%d 压缩=%d\n",
             (unsigned long long)idx, (unsigned long long)(tt + idx * 8),
             (unsigned long long)tte, (int)(tte & 1), (int)((tte >> 1) & 1),
             (tte & (MFP_PTE_COMPRESSED | MFP_PTE_COMP_ALT)) ? 1 : 0);
    if ((tte & MFP_PTE_TYPE_VALID) != MFP_PTE_TYPE_VALID) return -11;
    if (tte & (MFP_PTE_COMPRESSED | MFP_PTE_COMP_ALT)) return -12;

    pa = ((tte & MFP_MASK_16K) | (va & MFP_L3_OFFMASK));
    MFP_EMIT("      → 4 级页 pa=%#llx\n", (unsigned long long)pa);
    (void)rc;
    return 0;

#undef MFP_EMIT
}

static int mfpt_probe32_locked(uint64_t root, uint64_t va, uint32_t *out){
    uint64_t pa = 0, kva = 0;
    uint32_t v = 0;

    if (!out) return -2;
    if (mfpt_translate(root, va, &pa) != 0) {
        g_mfpt_failed++;
        return -1;
    }
    if (mfp_phys_to_kva(pa, &kva) != 0) {
        g_mfpt_failed++;
        return -1;
    }
    if (mfp_k32(kva, &v) != 0) {
        g_mfpt_failed++;
        return -1;
    }
    g_mfpt_translated++;
    *out = v;
    return 0;
}

/*
 * Lowest present page at or after `start`, read straight out of the target's
 * own L1/L2/L3 tables. Bounded work: we stop at the first present L3 entry, and
 * we never probe (read) an unmapped page.
 */
static int mfpt_lowest_mapped_page_locked(uint64_t root, uint64_t start, uint64_t *va_out)
{
    uint64_t i1_first, i2_first;

    if (!va_out || !mfp_is_kaddr(root)) return -2;
    *va_out = 0;

    i1_first = (start & MFP_L1_INDEX) >> MFP_L1_SHIFT;
    i2_first = (start & MFP_L2_INDEX) >> MFP_L2_SHIFT;

    for (uint64_t i1 = i1_first; i1 < i1_first + 8 && i1 < 2048; i1++) {
        uint64_t e1 = 0, l2_kva = 0;
        uint64_t l1_base = i1 << MFP_L1_SHIFT;

        if (mfp_k64(root + i1 * 8, &e1) != 0) continue;
        if ((e1 & MFP_TTE_VALID) != MFP_TTE_VALID) continue;

        if ((e1 & MFP_TTE_TYPE_MASK) == 0) {        /* 64 GB block */
            *va_out = l1_base > start ? l1_base : (start & ~(MFP_PAGE_SIZE - 1ULL));
            return 0;
        }
        if (mfp_phys_to_kva(e1 & MFP_MASK_16K, &l2_kva) != 0) continue;

        uint64_t i2_from = (i1 == i1_first) ? i2_first : 0;
        for (uint64_t i2 = i2_from; i2 < 2048; i2++) {
            uint64_t e2 = 0, l3_kva = 0;
            uint64_t l2_base = l1_base + (i2 << MFP_L2_SHIFT);

            if (mfp_k64(l2_kva + i2 * 8, &e2) != 0) continue;
            if ((e2 & MFP_TTE_VALID) != MFP_TTE_VALID) continue;

            if ((e2 & MFP_TTE_TYPE_MASK) == 0) {    /* 32 MB block */
                *va_out = (i1 == i1_first && i2 == i2_first)
                              ? (start & ~(MFP_PAGE_SIZE - 1ULL))
                              : l2_base;
                return 0;
            }
            if (mfp_phys_to_kva(e2 & MFP_MASK_16K, &l3_kva) != 0) continue;

            for (uint64_t i3 = 0; i3 < 2048; i3++) {
                uint64_t e3 = 0;
                uint64_t page = l2_base + (i3 << MFP_L3_SHIFT);

                if (page < start) continue;
                if (mfp_k64(l3_kva + i3 * 8, &e3) != 0) continue;
                if ((e3 & MFP_PTE_TYPE_VALID) != MFP_PTE_TYPE_VALID) continue;
                if (e3 & (MFP_PTE_COMPRESSED | MFP_PTE_COMP_ALT)) continue;

                *va_out = page;
                return 0;
            }
        }
    }
    return -3;
}

/*
 * 逐页读的实现（[M5.135] 改成"能读多少读多少"）。
 *
 * 以前任何一页失败就 return，前面读到的字节全部作废 —— 于是
 * "读一个 600 项的 Actor 指针数组"只要跨到一页没映射的就整批归零。
 *
 * 现在：失败就停，但把已经读到的长度写进 *got。
 *   - 返回 0  → 读到了东西（got 可能小于 n）
 *   - 返回 -2 → 参数非法
 *   - 返回 -3 → 一个字节都没读到
 *
 * 严格版（mfpt_read）自己再补一刀：got != n 就算失败，保持老语义；
 * 宽松版（mfpt_read_partial）把长度的裁量权交给调用方。
 */
static int mfpt_read_inner(uint64_t root, uint64_t va, void *dst, size_t n, size_t *got)
{
    unsigned char *p = (unsigned char *)dst;
    size_t done = 0;

    if (got) *got = 0;
    if (!dst || n == 0) return -2;

    while (done < n) {
        uint64_t cur = va + done;
        uint64_t page = cur & ~(MFP_PAGE_SIZE - 1ULL);
        uint64_t off = MFP_PAGE_OFF(cur);
        size_t take = (size_t)(MFP_PAGE_SIZE - off);
        uint64_t pa = 0, kva = 0;

        if (take > n - done) take = n - done;
        if (mfpt_translate(root, page, &pa) != 0) {
            g_mfpt_failed++;
            break;
        }
        if (mfp_phys_to_kva(pa, &kva) != 0) {
            g_mfpt_failed++;
            break;
        }
        /* 4 bytes at a time: that is all the sem_open primitive guarantees. */
        int page_ok = 1;
        for (size_t i = 0; i < take; i += 4) {
            uint32_t v = 0;
            size_t copy = take - i < 4 ? take - i : 4;
            if (mfp_k32(kva + off + i, &v) != 0) {
                g_mfpt_failed++;
                page_ok = 0;
                break;
            }
            memcpy(p + done + i, &v, copy);
        }
        if (!page_ok) break;
        g_mfpt_translated++;
        done += take;
    }

    if (got) *got = done;
    return done > 0 ? 0 : -3;
}

static int mfpt_read_locked(uint64_t root, uint64_t va, void *dst, size_t n)
{
    size_t got = 0;
    int rc = mfpt_read_inner(root, va, dst, n, &got);
    if (rc != 0) return rc;
    return (got == n) ? 0 : -3;
}

static int mfpt_read_partial_locked(uint64_t root, uint64_t va, void *dst, size_t n, size_t *got)
{
    return mfpt_read_inner(root, va, dst, n, got);
}

/* ================================================================ */
/* 串行化包装（[M5.135]）                                             */
/* ================================================================ */
/*
 * 一次翻译 = 3 次 kread，一次 mfpt_read 还要再读页面内容。这些步骤必须
 * 整体原子：
 *   · 中途被 mf_kclose 插进来 → 读到已释放的 kfd 状态；
 *   · 被另一条线程的翻译插进来 → v2p 缓存可能读到"root/vpage 已写、pbase
 *     还没写"的半成品条目，返回错误的物理页。
 *
 * 锁是递归的（见 MFKernelBridge.m），所以这里的 locked 版本内部继续调
 * mf_kread32 / mf_phys_to_kv 不会自锁。
 */

int mfpt_translate(uint64_t root, uint64_t va, uint64_t *pa)
{
    mf_lock_kernel();
    int rc = mfpt_translate_locked(root, va, pa);
    mf_unlock_kernel();
    return rc;
}

int mfpt_probe32(uint64_t root, uint64_t va, uint32_t *out)
{
    mf_lock_kernel();
    int rc = mfpt_probe32_locked(root, va, out);
    mf_unlock_kernel();
    return rc;
}

int mfpt_lowest_mapped_page(uint64_t root, uint64_t start, uint64_t *va_out)
{
    mf_lock_kernel();
    int rc = mfpt_lowest_mapped_page_locked(root, start, va_out);
    mf_unlock_kernel();
    return rc;
}

int mfpt_read(uint64_t root, uint64_t va, void *dst, size_t n)
{
    mf_lock_kernel();
    int rc = mfpt_read_locked(root, va, dst, n);
    mf_unlock_kernel();
    return rc;
}

int mfpt_read_partial(uint64_t root, uint64_t va, void *dst, size_t n, size_t *got)
{
    mf_lock_kernel();
    int rc = mfpt_read_partial_locked(root, va, dst, n, got);
    mf_unlock_kernel();
    return rc;
}
