//
//  MFReadBackend.mm — 跨进程内存读取后端（实现）
//
#import "MFReadBackend.h"
#import "../Kernel/MFKernelBridge.h"
#import "../Kernel/MFPageTable.h"
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <unistd.h>
#include <string.h>

// mach_vm_remap / mach_vm_deallocate 都是 iOS 的 SPI —— 公开 SDK 头里没有声明。
// 原实现同样是用 dlsym 拿 mach_vm_remap 的。
typedef kern_return_t (*mf_mach_vm_remap_fn)(
    vm_map_t target_task,
    mach_vm_address_t *target_address,
    mach_vm_size_t size,
    mach_vm_offset_t mask,
    int flags,
    vm_map_t src_task,
    mach_vm_address_t src_address,
    boolean_t copy,
    vm_prot_t *cur_protection,
    vm_prot_t *max_protection,
    vm_inherit_t inheritance);

typedef kern_return_t (*mf_mach_vm_deallocate_fn)(
    vm_map_t target,
    mach_vm_address_t address,
    mach_vm_size_t size);

static mf_mach_vm_remap_fn      g_remap    = NULL;
static mf_mach_vm_deallocate_fn g_dealloc  = NULL;
static uint64_t g_pagesize = 0;

/// 解除映射：优先用 SPI 版 mach_vm_deallocate（支持 >4GB 地址），
/// 拿不到就退回公开的 vm_deallocate。
///
/// ★ 审查修正（报告 G1）：第一版无条件回退到 vm_deallocate，
///   而 vm_address_t 是 32 位的 —— 映射地址 ≥ 4GB 时会被静默截断，
///   解除映射作用到错误地址上，本页就【永远泄漏】。
///   现在：地址放不进 32 位时明确失败，不再悄悄截断。
static inline kern_return_t mf_dealloc(vm_map_t task, mach_vm_address_t addr, mach_vm_size_t size) {
    if (g_dealloc) return g_dealloc(task, addr, size);

    if (addr > 0xFFFFFFFFULL || size > 0xFFFFFFFFULL) {
        NSLog(@"[MF][Read] ⚠️ mach_vm_deallocate 不可用且地址/长度超出 32 位"
              @"（addr=0x%llx size=0x%llx）—— 这一页会泄漏",
              (unsigned long long)addr, (unsigned long long)size);
        return KERN_INVALID_ADDRESS;
    }
    return vm_deallocate(task, (vm_address_t)addr, (vm_size_t)size);
}

@implementation MFReadBackend {
    uint64_t _readCount;
    uint64_t _failCount;
}

+ (instancetype)shared {
    static MFReadBackend *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFReadBackend alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        // 对齐原实现初始化：dlsym("mach_vm_remap") + getpagesize()
        g_remap = (mf_mach_vm_remap_fn)dlsym(RTLD_DEFAULT, "mach_vm_remap");
        if (!g_remap) g_remap = (mf_mach_vm_remap_fn)dlsym(RTLD_DEFAULT, "_mach_vm_remap");
        g_dealloc = (mf_mach_vm_deallocate_fn)dlsym(RTLD_DEFAULT, "mach_vm_deallocate");
        if (!g_dealloc) g_dealloc = (mf_mach_vm_deallocate_fn)dlsym(RTLD_DEFAULT, "_mach_vm_deallocate");
        g_pagesize = (uint64_t)getpagesize();
        if (!g_pagesize) g_pagesize = 0x4000;
        _modeFlag = NO;
        NSLog(@"[MF][Read] 后端就绪 remap=%p dealloc=%p(回退 vm_deallocate) pagesize=0x%llx",
              (void *)g_remap, (void *)g_dealloc, g_pagesize);
    }
    return self;
}

#pragma mark - 门条件

- (BOOL)gateOpen {
    // 对齐原 sub_10099A034：模式标记 == 1 且 端口 != 0
    // [M5.117] 但走 KFD 页表直读时不需要 task port —— 有根表就够
    if (self.kfdRoot != 0 && self.modeFlag) {
        return YES;
    }
    return self.modeFlag && self.targetTaskPort != MACH_PORT_NULL;
}

/*
 * [M5.117] 把读取后端切到 KFD 页表直读。
 *
 * 原来的实现走 mach_vm_remap + 目标 task port，而 task_for_pid 对 App Store
 * 正版（自带反作弊）必然 kr=0x5 —— 这条路在我们目标上是死的。
 * 现在改成：pid → pmap 根表（mf_pid_chain），之后每个 readRemote 都用
 * mfpt_read 走目标自己的页表，完全不碰 task port。
 *
 * 返回 YES 表示根表已就位；此后的 readU64/readInt32/followChain 等封装
 * 全部自动走 KFD，上层 UE4 读取代码一行都不用改。
 */
- (BOOL)attachKFDPid:(int)pid {
    uint64_t root = 0;
    char why[192] = {0};
    int rc = mf_pid_chain(pid, NULL, NULL, NULL, NULL, &root, why, sizeof(why));
    if (rc != 0 || root == 0) {
        NSLog(@"[MF][Read] attachKFDPid(%d) 失败 rc=%d %s", pid, rc, why);
        self.kfdRoot = 0;
        self.kfdPid = 0;
        return NO;
    }
    self.kfdPid = pid;
    self.kfdRoot = root;
    self.modeFlag = YES;
    mfpt_cache_reset();
    NSLog(@"[MF][Read] KFD 后端就绪 pid=%d root=0x%llx", pid, (unsigned long long)root);
    return YES;
}

- (void)detachKFD {
    self.kfdRoot = 0;
    self.kfdPid = 0;
    mfpt_cache_reset();
}

- (void)setTargetTaskPort:(uint32_t)port {
    _targetTaskPort = port;
    self.modeFlag = (port != MACH_PORT_NULL);
    NSLog(@"[MF][Read] 目标端口 = 0x%x，门 %@", port, self.gateOpen ? @"已就绪" : @"未就绪");
}

#pragma mark - 底层读取

- (BOOL)readRemote:(uint64_t)remote into:(void *)out size:(size_t)size {
    if (!out || size == 0) return NO;

    /*
     * [M5.117] KFD 页表直读优先。
     * 目标进程的 task port 拿不到（PPL 封死），这条路是唯一可用的；
     * 有根表时完全不碰 mach_vm_remap。
     */
    if (self.kfdRoot != 0) {
        uint64_t translated = 0;
        if (mfpt_translate(self.kfdRoot, remote, &translated) == 0) {
            _readCount++;
            return mfpt_read(self.kfdRoot, remote, out, size) == 0;
        }
        _failCount++;
        return NO;
    }

    // 门判不过 → 不进入 remap 分支（原实现同样行为）
    if (!self.gateOpen) {
        _failCount++;
        return NO;
    }
    if (!g_remap) {
        _failCount++;
        return NO;
    }

    // 页对齐
    uint64_t aligned = remote & ~(g_pagesize - 1);
    uint64_t offset  = remote - aligned;

    // 请求长度跨页也要能读：算出要映射几页
    uint64_t span   = (offset + size + g_pagesize - 1) & ~(g_pagesize - 1);
    if (span == 0) span = g_pagesize;

    mach_vm_address_t local = 0;
    vm_prot_t cur = VM_PROT_READ, max = VM_PROT_READ;

    kern_return_t kr = g_remap(mach_task_self(), &local, span, 0,
                               VM_FLAGS_ANYWHERE,
                               self.targetTaskPort, aligned,
                               /* copy = */ TRUE,
                               &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        _failCount++;
        return NO;
    }

    /*
     * ★ 审查修正（报告 G3）：原版在 memcpy 前检查过映射地址非 0，
     *   第一版漏掉了。极端情况下（例如目标页是零页）remap 可能返回
     *   成功但 local == 0 —— 那 memcpy 就会从 0 地址读，直接崩。
     */
    if (local == 0) {
        _failCount++;
        return NO;
    }

    memcpy(out, (void *)(local + offset), size);
    mf_dealloc(mach_task_self(), local, span);

    _readCount++;
    return YES;
}

#pragma mark - 六个字节封装

- (BOOL)readU64:(uint64_t)addr out:(uint64_t *)out {
    uint64_t v = 0;
    if (![self readRemote:addr into:&v size:8]) {
        if (out) *out = 0;
        return NO;      // 对齐原实现：失败 → 0
    }
    if (out) *out = v;
    return YES;
}

- (uint64_t)readU64:(uint64_t)addr {
    uint64_t v = 0;
    [self readU64:addr out:&v];
    return v;
}

- (BOOL)readFloat3:(uint64_t)addr out:(float *)v3 {
    float tmp[3] = {0, 0, 0};
    if (![self readRemote:addr into:tmp size:12]) {
        // 对齐原实现：读失败 → 返回 0.0（fcsel s2, s3(wzr), s2, ne）
        if (v3) { v3[0] = v3[1] = v3[2] = 0.0f; }
        return NO;
    }
    if (v3) { v3[0] = tmp[0]; v3[1] = tmp[1]; v3[2] = tmp[2]; }
    return YES;
}

- (float)readFloat:(uint64_t)addr {
    float v = 0.0f;
    if (![self readRemote:addr into:&v size:4]) return 0.0f;
    return v;
}

- (int32_t)readInt32:(uint64_t)addr {
    int32_t v = 0;
    if (![self readRemote:addr into:&v size:4]) return 0;
    return v;
}

- (BOOL)readCameraStruct:(uint64_t)addr out:(float *)v12 {
    float tmp[12] = {0};
    if (![self readRemote:addr into:tmp size:48]) {
        if (v12) memset(v12, 0, sizeof(float) * 12);
        return NO;
    }
    if (v12) memcpy(v12, tmp, sizeof(float) * 12);
    return YES;
}

#pragma mark - 指针链

- (uint64_t)followChain:(uint64_t)base offsets:(NSArray<NSNumber *> *)offsets {
    if (!offsets.count) return base;
    uint64_t cur = base;
    for (NSUInteger i = 0; i < offsets.count; i++) {
        uint64_t off = offsets[i].unsignedLongLongValue;
        uint64_t next = [self readU64:cur + off];
        if (next == 0) return 0;                    // 链断
        cur = next;
    }
    return cur;
}

#pragma mark - 诊断

- (NSString *)statsText {
    uint64_t total = _readCount + _failCount;
    double rate = total ? (_readCount * 100.0 / total) : 0.0;
    return [NSString stringWithFormat:@"读取 %llu 次 · 失败 %llu 次 · 成功率 %.1f%%\n门：%@ · 端口 0x%x · 页 0x%llx",
            _readCount, _failCount, rate,
            self.gateOpen ? @"开" : @"关", self.targetTaskPort, g_pagesize];
}

- (void)resetStats {
    _readCount = 0;
    _failCount = 0;
}

@end
