#import "MFModuleLocator.h"

#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/vm_region.h>
#import <mach/task_info.h>
#import <sys/sysctl.h>
#import <sys/proc.h>          /* struct kinfo_proc */
#import <sys/param.h>         /* MAXCOMLEN */
#import <libkern/OSByteOrder.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

/*
 * ── 为什么自己定义这些结构体 ──
 *
 * <mach-o/dyld_images.h> 在 iOS SDK 里存在，但：
 *   · dyld_all_image_infos 的字段随 iOS 版本增加，头文件版本与本机不一定一致
 *   · 我们其实只用到前 0x10 字节（version / infoArrayCount / infoArray）
 *
 * 所以按「已知稳定的最小布局」自己定义，只读我们需要的字段。
 * infoArray 在 +0x8 —— 这个位置从 iOS 5 到 16 一直没变（dyld 要保持 ABI 兼容）。
 */
struct mf_dyld_image_info {
    uint64_t imageLoadAddress;     // +0x0
    uint64_t imageFilePath;        // +0x8
    uint64_t imageFileModDate;     // +0x10
};

struct mf_dyld_all_image_infos {
    uint32_t version;              // +0x0
    uint32_t infoArrayCount;       // +0x4
    uint64_t infoArray;            // +0x8  ← 只用这个
};

/* task_info(TASK_DYLD_INFO) 的返回结构 */
struct mf_task_dyld_info {
    uint64_t all_image_info_addr;  // +0x0
    uint64_t all_image_info_size;  // +0x8
    int32_t  all_image_info_format;// +0x10
};

/*
 * ── 为什么用 dlsym ──
 *
 * mach_vm_read_overwrite / mach_vm_region 都是 iOS 私有 SPI：
 *   · 公开 SDK 的 <mach/mach_vm.h> 里【没有声明】
 *   · 直接调用会报 use of undeclared identifier
 *   · 但符号在 /usr/lib/system/libsystem_kernel.dylib 里【确实存在】
 *
 * 和 MFReadBackend 里 mach_vm_remap 的做法一致：dlsym 拿函数指针。
 * 这样既能绕过头文件缺失，也不影响 App Store 之外的签名（我们本来就不用商店）。
 */
typedef kern_return_t (*mf_vm_read_overwrite_t)(vm_map_t target,
                                                mach_vm_address_t address,
                                                mach_vm_size_t size,
                                                mach_vm_address_t data,
                                                mach_vm_size_t *outsize);

typedef kern_return_t (*mf_vm_region_t)(vm_map_t target_task,
                                        mach_vm_address_t *address,
                                        mach_vm_size_t *size,
                                        vm_region_flavor_t flavor,
                                        vm_region_info_t info,
                                        mach_msg_type_number_t *infoCnt,
                                        mach_port_t *object_name);

static mf_vm_read_overwrite_t g_vm_read_overwrite = NULL;
static mf_vm_region_t         g_vm_region         = NULL;
static dispatch_once_t        g_dlsym_once;

static void MFResolveVMSPI(void) {
    dispatch_once(&g_dlsym_once, ^{
        void *h = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_LAZY);
        if (h == NULL) h = dlopen(NULL, RTLD_LAZY);       // 兜底：主程序符号
        if (h != NULL) {
            g_vm_read_overwrite = (mf_vm_read_overwrite_t)dlsym(h, "mach_vm_read_overwrite");
            g_vm_region         = (mf_vm_region_t)dlsym(h, "mach_vm_region");
        }
        NSLog(@"[MF][Module] SPI: read_overwrite=%p region=%p",
              (void *)g_vm_read_overwrite, (void *)g_vm_region);
    });
}

/// SPI 是否齐全
static BOOL MFVMSPIReady(void) {
    MFResolveVMSPI();
    return (g_vm_read_overwrite != NULL);
}

static NSString *gLastReport = nil;

@implementation MFModuleInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ base=0x%llx size=%.2fMB%@>",
            self.name, self.base, self.size / 1048576.0, self.isMain ? @" [主]" : @""];
}

/// 人类可读大小
- (NSString *)sizeText {
    if (self.size == 0) return @"—";
    if (self.size >= 1048576) return [NSString stringWithFormat:@"%.1f MB", self.size / 1048576.0];
    if (self.size >= 1024)    return [NSString stringWithFormat:@"%.1f KB", self.size / 1024.0];
    return [NSString stringWithFormat:@"%llu B", self.size];
}
@end

@implementation MFModuleLocator

+ (instancetype)shared {
    static MFModuleLocator *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[MFModuleLocator alloc] init]; });
    return s;
}

+ (NSString *)lastReport { return gLastReport ?: @"（还没有执行过模块定位）"; }

#pragma mark - 进程查找

+ (pid_t)pidForProcessName:(NSString *)name {
    if (name.length == 0) return -1;

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return -1;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (procs == NULL) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return -1; }

    pid_t found = -1;
    const char *want = name.UTF8String;
    int n = (int)(len / sizeof(struct kinfo_proc));
    for (int i = 0; i < n; i++) {
        // p_comm 是进程短名（最多 MAXCOMLEN 字节）。
        // 注意：kp_proc.p_comm 与实际可执行名一致，改过名的进程会不同。
        if (strncmp(procs[i].kp_proc.p_comm, want, MAXCOMLEN) == 0) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return found;
}

+ (mach_port_t)taskPortForPid:(pid_t)pid {
    if (pid <= 0) return MACH_PORT_NULL;

    /*
     * 和 MFKernel 的路 C 一致 —— 靠 task_for_pid-allow entitlement。
     * 注意：端口名只在【创建它的 IPC space】有效。
     *       HUD 子进程要自己再取一份（不能复用父进程的端口号）。
     */
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) return MACH_PORT_NULL;
    return task;
}

#pragma mark - 模块遍历（路 A：TASK_DYLD_INFO）

/// 远程读：只读，不修改目标
static BOOL MFRemoteRead(mach_port_t task, uint64_t addr, void *buf, size_t size) {
    if (task == MACH_PORT_NULL || addr == 0 || size == 0) return NO;
    if (!MFVMSPIReady()) return NO;
    mach_vm_size_t out = 0;
    kern_return_t kr = g_vm_read_overwrite(task, (mach_vm_address_t)addr,
                                           (mach_vm_size_t)size,
                                           (mach_vm_address_t)(uintptr_t)buf,
                                           &out);
    return (kr == KERN_SUCCESS && out == size);
}

/// 远程读 C 字符串（最多读 max 字节，保证有结束符）
static NSString *MFRemoteString(mach_port_t task, uint64_t addr, size_t max) {
    if (addr == 0) return nil;
    char *buf = (char *)malloc(max + 1);
    if (buf == NULL) return nil;
    memset(buf, 0, max + 1);
    if (!MFRemoteRead(task, addr, buf, max)) { free(buf); return nil; }
    buf[max] = '\0';
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s;
}

+ (NSArray<MFModuleInfo *> *)modulesByDyldInfoForPid:(pid_t)pid
                                                task:(mach_port_t)task
                                          report:(NSMutableString *)rep {
    // ① task_info 拿 dyld 信息块地址
    struct mf_task_dyld_info di = {0};
    mach_msg_type_number_t count = sizeof(di) / sizeof(integer_t);
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &count);
    if (kr != KERN_SUCCESS) {
        [rep appendFormat:@"  ✗ task_info(TASK_DYLD_INFO) 失败 kr=%d(0x%x)\n", kr, kr];
        return nil;
    }
    [rep appendFormat:@"  ✓ dyld 信息块 @ 0x%llx（%llu 字节，format=%d）\n",
        di.all_image_info_addr, di.all_image_info_size, di.all_image_info_format];
    if (di.all_image_info_addr == 0) {
        [rep appendString:@"  ✗ all_image_info_addr 为 0\n"];
        return nil;
    }

    // ② 读 dyld_all_image_infos 的头 0x10 字节
    struct mf_dyld_all_image_infos ai = {0};
    if (!MFRemoteRead(task, di.all_image_info_addr, &ai, sizeof(ai))) {
        [rep appendString:@"  ✗ 读 dyld_all_image_infos 失败\n"];
        return nil;
    }
    [rep appendFormat:@"  ✓ dyld_all_image_infos: version=%u count=%u array=0x%llx\n",
        ai.version, ai.infoArrayCount, ai.infoArray];

    if (ai.infoArrayCount == 0 || ai.infoArrayCount > 8192 || ai.infoArray == 0) {
        [rep appendFormat:@"  ✗ 映像数量异常（%u）\n", ai.infoArrayCount];
        return nil;
    }

    // ③ 读映像数组
    size_t arrBytes = (size_t)ai.infoArrayCount * sizeof(struct mf_dyld_image_info);
    struct mf_dyld_image_info *arr = (struct mf_dyld_image_info *)malloc(arrBytes);
    if (arr == NULL) return nil;
    if (!MFRemoteRead(task, ai.infoArray, arr, arrBytes)) {
        [rep appendString:@"  ✗ 读映像数组失败\n"];
        free(arr);
        return nil;
    }

    // ④ 逐个读路径
    NSMutableArray<MFModuleInfo *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (uint32_t i = 0; i < ai.infoArrayCount; i++) {
        @autoreleasepool {
            uint64_t base = arr[i].imageLoadAddress;
            NSString *path = MFRemoteString(task, arr[i].imageFilePath, 0x400);
            if (base == 0 || path.length == 0) continue;
            if (![seen containsObject:path]) [seen addObject:path];
            else continue;                              // 去重（同一模块可能重复登记）

            MFModuleInfo *m = [[MFModuleInfo alloc] init];
            m.path = path;
            m.name = path.lastPathComponent;
            m.base = base;
            m.size = 0;                                 // 路 A 拿不到大小
            m.isMain = (i == 0);
            [out addObject:m];
        }
    }
    free(arr);
    [rep appendFormat:@"  ✓ 解析出 %lu 个模块\n", (unsigned long)out.count];
    return out;
}

#pragma mark - 模块遍历（路 B：mach_vm_region 兜底）

/// 路 A 被拦时的替代：直接扫地址空间，按 region 名匹配。
/// 缺点：拿不到路径（只有区域名），且慢。所以只当兜底。
+ (NSArray<MFModuleInfo *> *)modulesByRegionForPid:(pid_t)pid
                                              task:(mach_port_t)task
                                            report:(NSMutableString *)rep {
    NSMutableArray<MFModuleInfo *> *out = [NSMutableArray array];
    if (!MFVMSPIReady() || g_vm_region == NULL) {
        [rep appendString:@"  ✗ mach_vm_region 不可用（dlsym 失败）\n"];
        return out;
    }
    mach_vm_address_t addr = 0;
    int scanned = 0;

    while (scanned < 20000) {                            // 上限：防失控
        mach_vm_size_t rsize = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t icount = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        kern_return_t kr = g_vm_region(task, &addr, &rsize, VM_REGION_BASIC_INFO_64,
                                       (vm_region_info_t)&info, &icount, &obj);
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
        if (kr != KERN_SUCCESS) break;
        scanned++;

        /* 只关心 __TEXT 段（可执行、非共享）—— 模块头就在那 */
        BOOL isText = (info.protection & VM_PROT_EXECUTE) && !(info.shared);
        if (isText && rsize > 1048576) {                 // 只留 >1MB 的，滤掉小库
            MFModuleInfo *m = [[MFModuleInfo alloc] init];
            m.path = @"(路径未知)";
            m.name = [NSString stringWithFormat:@"<region 0x%llx>", (uint64_t)addr];
            m.base = (uint64_t)addr;
            m.size = (uint64_t)rsize;
            m.isMain = NO;
            [out addObject:m];
        }
        addr += rsize;
    }
    [rep appendFormat:@"  ✓ 路 B 扫了 %d 个区域，命中 %lu 个大模块\n",
        scanned, (unsigned long)out.count];
    return out;
}

#pragma mark - 对外

+ (NSArray<MFModuleInfo *> *)modulesForPid:(pid_t)pid
                                      error:(NSString **)error {
    NSMutableString *rep = [NSMutableString string];
    [rep appendFormat:@"=== 模块定位诊断 ===\npid=%d\n", pid];

    if (pid <= 0) {
        if (error) *error = @"pid 无效";
        gLastReport = rep;
        return nil;
    }

    mach_port_t task = [self taskPortForPid:pid];
    if (task == MACH_PORT_NULL) {
        [rep appendString:@"✗ 拿不到 task port（task_for_pid 失败）\n"];
        if (error) *error = @"拿不到 task port —— 检查 task_for_pid-allow 权限";
        gLastReport = rep;
        return nil;
    }
    [rep appendFormat:@"✓ task port = 0x%x\n", task];

    // 先走路 A
    [rep appendString:@"\n[路 A] TASK_DYLD_INFO\n"];
    NSArray<MFModuleInfo *> *mods = [self modulesByDyldInfoForPid:pid task:task report:rep];

    // 路 A 失败 → 路 B
    if (mods.count == 0) {
        [rep appendString:@"\n[路 B] mach_vm_region 兜底\n"];
        mods = [self modulesByRegionForPid:pid task:task report:rep];
    }

    // 试着补大小：整块已加载地址空间里，同名相邻的合并
    if (mods.count > 0) {
        [self fillSizes:mods pid:pid task:task];
        mods = [mods sortedArrayUsingComparator:^NSComparisonResult(MFModuleInfo *a, MFModuleInfo *b) {
            if (a.size != b.size) return a.size > b.size ? NSOrderedAscending : NSOrderedDescending;
            return a.base < b.base ? NSOrderedAscending : NSOrderedDescending;
        }];
    }

    mach_port_deallocate(mach_task_self(), task);

    [rep appendFormat:@"\n合计 %lu 个模块\n", (unsigned long)mods.count];
    gLastReport = rep;
    if (error) *error = nil;
    return mods;
}

/// 用 mach_vm_region 给每个模块量一下大小（只量模块起始那一块，代价很低）
+ (void)fillSizes:(NSArray<MFModuleInfo *> *)mods pid:(pid_t)pid task:(mach_port_t)task {
    if (!MFVMSPIReady() || g_vm_region == NULL) return;
    for (MFModuleInfo *m in mods) {
        if (m.size > 0) continue;
        mach_vm_address_t addr = (mach_vm_address_t)m.base;
        mach_vm_size_t rsize = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t icount = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (g_vm_region(task, &addr, &rsize, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &icount, &obj) == KERN_SUCCESS) {
            m.size = (uint64_t)rsize;
        }
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    }
}

+ (MFModuleInfo *)mainModuleForPid:(pid_t)pid error:(NSString **)error {
    NSArray<MFModuleInfo *> *mods = [self modulesForPid:pid error:error];
    if (mods.count == 0) return nil;

    NSMutableString *rep = [NSMutableString stringWithString:gLastReport ?: @""];

    /* 判定顺序：
     *   ① 名字里含已知 UE4 特征 —— UE4 的 iOS 包通常叫 UE4Game / libUE4 / 或就是主可执行名
     *   ② 体积最大的那个 —— UE4 模块 300~600 MB，其余模块都是几十 KB~几 MB
     *      （mingyun 的 GWorld 偏移 0x178AA5E0 ≈ 377 MB，说明 sLibBase 指向的就是那个大模块）
     */
    MFModuleInfo *picked = nil;
    NSString *why = nil;

    NSArray<NSString *> *hints = @[@"UE4", @"UE4Game", @"DeltaForce", @"libUE4"];
    for (NSString *h in hints) {
        for (MFModuleInfo *m in mods) {
            if ([m.name rangeOfString:h options:NSCaseInsensitiveSearch].location != NSNotFound) {
                picked = m; why = [NSString stringWithFormat:@"名字命中「%@」", h];
                break;
            }
        }
        if (picked) break;
    }

    if (picked == nil) {
        // 按大小取最大（mods 已按 size 降序排过）
        uint64_t maxSize = 0;
        for (MFModuleInfo *m in mods) if (m.size > maxSize) { maxSize = m.size; picked = m; }
        why = maxSize > 0
            ? [NSString stringWithFormat:@"取体积最大者（%.1f MB）", maxSize / 1048576.0]
            : @"无用信息";
    }

    picked.isMain = YES;

    [rep appendFormat:@"\n=== 判定结果 ===\n依据：%@\n模块：%@\n基址：0x%llx\n大小：%@\n路径：%@\n",
        why, picked.name, picked.base, [picked sizeText], picked.path];
    gLastReport = rep;

    NSLog(@"[MF][Module] 主模块 = %@ base=0x%llx (%@)", picked.name, picked.base, why);
    return picked;
}

+ (MFModuleInfo *)locateProcess:(NSString *)processName error:(NSString **)error {
    NSMutableString *rep = [NSMutableString string];
    [rep appendFormat:@"=== 定位进程 %@ ===\n", processName];

    pid_t pid = [self pidForProcessName:processName];
    if (pid <= 0) {
        [rep appendFormat:@"✗ 没找到进程「%@」\n"
                            @"  可能原因：游戏没运行 / 进程名不对 / mobile 身份看不到它\n", processName];
        gLastReport = rep;
        if (error) *error = [NSString stringWithFormat:@"没找到进程 %@", processName];
        return nil;
    }
    [rep appendFormat:@"✓ pid = %d\n", pid];

    MFModuleInfo *m = [self mainModuleForPid:pid error:error];
    // 把两段报告拼起来
    gLastReport = [NSString stringWithFormat:@"%@\n%@", rep, gLastReport ?: @""];
    return m;
}

@end
