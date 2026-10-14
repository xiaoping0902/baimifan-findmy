//
//  MFReadBackend.mm — 跨进程内存读取后端（实现）
//
#import "MFReadBackend.h"
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
/// 拿不到就退回公开的 vm_deallocate
static inline kern_return_t mf_dealloc(vm_map_t task, mach_vm_address_t addr, mach_vm_size_t size) {
    if (g_dealloc) return g_dealloc(task, addr, size);
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
    return self.modeFlag && self.targetTaskPort != MACH_PORT_NULL;
}

- (void)setTargetTaskPort:(uint32_t)port {
    _targetTaskPort = port;
    self.modeFlag = (port != MACH_PORT_NULL);
    NSLog(@"[MF][Read] 目标端口 = 0x%x，门 %@", port, self.gateOpen ? @"已就绪" : @"未就绪");
}

#pragma mark - 底层读取

- (BOOL)readRemote:(uint64_t)remote into:(void *)out size:(size_t)size {
    if (!out || size == 0) return NO;

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
