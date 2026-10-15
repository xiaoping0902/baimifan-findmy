#import "MFEnvCheck.h"
#import "MFPaths.h"
#import "MFAntiBan.h"
#import "../Kernel/MFKernel.h"
#import "../Game/MFGameReader.h"
#import "../Read/MFReadBackend.h"

#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <sys/resource.h>
#import <sys/stat.h>
#import <sys/mount.h>      /* statfs 在这里（iOS 没有 sys/statfs.h，那是 Linux 的） */
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>

@implementation MFEnvItem
- (NSString *)symbol {
    switch (self.status) {
        case MFEnvStatusPass: return @"✓";
        case MFEnvStatusWarn: return @"⚠";
        case MFEnvStatusFail: return @"✗";
        default:              return @"·";
    }
}
@end

@interface MFEnvCheck ()
@property (nonatomic, strong) NSArray<MFEnvItem *> *last;
@end

@implementation MFEnvCheck

+ (instancetype)shared {
    static MFEnvCheck *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFEnvCheck alloc] init]; });
    return s;
}

static MFEnvItem *MK(NSString *n, NSString *v, MFEnvStatus st, NSString *d) {
    MFEnvItem *i = [[MFEnvItem alloc] init];
    i.name = n; i.value = v; i.status = st; i.detail = d;
    return i;
}

#pragma mark - 各项检测

/// 是否存在（不跟随符号链接）
static BOOL MFExists(NSString *p) {
    struct stat st;
    return lstat(p.fileSystemRepresentation, &st) == 0;
}

/// 目录是否可列（用 opendir 而不是 fileExists，权限不足时前者会失败）
static BOOL MFCanList(NSString *p) {
    DIR *d = opendir(p.fileSystemRepresentation);
    if (d) { closedir(d); return YES; }
    return NO;
}

- (NSArray<MFEnvItem *> *)run {
    NSMutableArray<MFEnvItem *> *out = [NSMutableArray array];

    // ── ① 设备与系统 ──
    struct utsname u; uname(&u);
    char model[128] = {0}; size_t ms = sizeof(model);
    sysctlbyname("hw.machine", model, &ms, NULL, 0);
    NSString *sysver = [NSString stringWithFormat:@"%@ %s",
                        UIDevice.currentDevice.systemName,
                        UIDevice.currentDevice.systemVersion.UTF8String];
    [out addObject:MK(@"设备与系统",
                      [NSString stringWithFormat:@"%s · %@", model, sysver],
                      MFEnvStatusInfo,
                      @"机型决定了内核地址常量（t1sz_boot / arm64_link_addr）")];

    // ── ② 进程身份 ──
    uid_t uid = getuid();
    [out addObject:MK(@"运行身份",
                      [NSString stringWithFormat:@"uid=%d gid=%d euid=%d",
                       uid, getgid(), geteuid()],
                      MFEnvStatusInfo,
                      @"原版特权功能会派生 uid=0 的子进程；主进程在 mobile(501) 是正常的")];

    // ── ③ 沙盒豁免（entitlements 是否真生效）──
    struct { NSString *path; NSString *label; } checks[] = {
        { @"/var/Keychains",         @"/var/Keychains" },
        { @"/var/mobile",            @"/var/mobile" },
        { @"/Applications",          @"/Applications" },
        { @"/var/containers/Shared", @"/var/containers/Shared" },
    };
    int sbPass = 0, sbTotal = 0;
    NSMutableString *sbDetail = [NSMutableString string];
    for (int i = 0; i < 4; i++) {
        sbTotal++;
        BOOL can = MFCanList(checks[i].path);
        if (can) sbPass++;
        [sbDetail appendFormat:@"%@%@%@  ", can ? @"✓" : @"✗",
                               checks[i].label, can ? @"" : @"(不可列)"];
    }
    [out addObject:MK(@"沙盒豁免",
                      [NSString stringWithFormat:@"%d/%d 可读", sbPass, sbTotal],
                      sbPass == sbTotal ? MFEnvStatusPass
                                        : (sbPass > 0 ? MFEnvStatusWarn : MFEnvStatusFail),
                      [NSString stringWithFormat:
                       @"%@\n依据：com.apple.private.security.no-sandbox 是否真生效。"
                       @"这条不通，清理/防封/读 Keychain 全部不可用。", sbDetail])];

    // ── ④ fd 上限（KFD 的硬门槛）──
    struct rlimit rl = {0,0};
    getrlimit(RLIMIT_NOFILE, &rl);
    int mfp = 0; size_t mfps = sizeof(mfp);
    sysctlbyname("kern.maxfilesperproc", &mfp, &mfps, NULL, 0);
    BOOL fdOK = (rl.rlim_max >= 10000 || mfp >= 10000);
    [out addObject:MK(@"fd 上限",
                      [NSString stringWithFormat:@"soft=%llu hard=%llu · maxfilesperproc=%d",
                       (unsigned long long)rl.rlim_cur,
                       (unsigned long long)rl.rlim_max, mfp],
                      fdOK ? MFEnvStatusPass : MFEnvStatusFail,
                      @"KFD 的 kread_sem_open 要为每个 id 开一个 fd，峰值约 1 万个。"
                      @"这里不够 → kopen 必然失败（会看到 sem_open 断言）。")];

    // ── ⑤ 内核版本与机型判定 ──
    NSString *kv = [MFKernel kernelVersion];
    if (kv.length == 0) kv = @"读取失败";
    BOOL isM = [kv containsString:@"T8103"] || [kv containsString:@"T8112"];
    [out addObject:MK(@"内核版本",
                      kv.length > 60 ? [kv substringToIndex:60] : kv,
                      MFEnvStatusInfo,
                      [NSString stringWithFormat:
                       @"机型判定：%@\n"
                       @"这决定内核地址常量（arm64_link_addr / t1sz_boot），"
                       @"也是能不能用 KFD 的前提。",
                       isM ? @"M 系列 → 0xFFFFFE0007004000 / t1sz=17"
                           : @"A 系列 → 0xFFFFFFF007004000 / t1sz=25"])];

    // ── ⑥ 越狱残留 ──
    NSArray *jbPaths = @[@"/var/jb", @"/var/lib/dpkg", @"/Applications/Cydia.app",
                         @"/Applications/Sileo.app", @"/usr/sbin/sshd",
                         @"/.bootstrapped_electra", @"/private/preboot", @"/usr/lib/libhooker.dylib"];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *p in jbPaths) if (MFExists(p)) [found addObject:p];
    [out addObject:MK(@"越狱残留",
                      found.count ? [found componentsJoinedByString:@" · "] : @"无",
                      found.count ? MFEnvStatusWarn : MFEnvStatusPass,
                      @"有残留不一定是坏事（TrollStore 环境本来就有），"
                      @"但会影响某些检测。列出来是为了心里有数。")] ;

    // ── ⑦ TrollStore ──
    BOOL ts = MFExists(@"/var/mobile/Library/Preferences/com.opa334.TrollStore.plist")
           || MFExists(@"/Applications/TrollStore.app")
           || MFExists(@"/var/mobile/Library/Preferences/com.opa334.TrollStorePreferences.plist");
    [out addObject:MK(@"TrollStore",
                      ts ? @"已安装" : @"未检测到",
                      ts ? MFEnvStatusPass : MFEnvStatusWarn,
                      @"本 App 的 platform-application 权限依赖它。"
                      @"⚠️ 清理系统残留的保护名单已包含 com.opa334，不会被误删。")];

    // ── ⑧ 内核链状态 ──
    MFKernel *k = [MFKernel shared];
    BOOL kopen = [k isOpen];
    MFEnumRoute route = [k availableRoute];
    NSString *routeText;
    switch (route) {
        case MFEnumRouteTaskForPid: routeText = @"路 C task_for_pid";     break;
        case MFEnumRoutePrivileged: routeText = @"路 A host_priv";        break;
        case MFEnumRouteDefault:    routeText = @"路 B processor_set";    break;
        default:                    routeText = @"未探测/均不可用";        break;
    }
    [out addObject:MK(@"内核链",
                      kopen ? [NSString stringWithFormat:@"已启动 · kbase=0x%llx",
                               (unsigned long long)k.kbase] : @"未启动",
                      kopen ? MFEnvStatusPass : MFEnvStatusInfo,
                      [NSString stringWithFormat:
                       @"枚举路：%@\n"
                       @"注意：KFD 失败过一次后本次运行会禁止重试（防内核泄漏叠加）", routeText])];

    // ── ⑨ 读取链 ──
    MFReadBackend *rb = [MFReadBackend shared];
    MFGameReader *r = [MFGameReader shared];
    BOOL hasPort = (r.targetTaskPort != MACH_PORT_NULL);
    [out addObject:MK(@"读取链",
                      hasPort ? [NSString stringWithFormat:@"已绑定 pid · port=0x%x",
                                 r.targetTaskPort] : @"未绑定目标",
                      hasPort ? MFEnvStatusPass : MFEnvStatusInfo,
                      [NSString stringWithFormat:
                       @"门=%s · 基址 root=0x%llx ent=0x%llx loot=0x%llx\n"
                       @"基址为 0 时绘制层整帧跳过（不崩，也画不出来）—— 去「基址校准」填",
                       rb.gateOpen ? "开" : "关",
                       (unsigned long long)r.rootObjectBase,
                       (unsigned long long)r.entityArrayBase,
                       (unsigned long long)r.lootArrayBase])];

    // ── ⑩ 防封目标 ──
    NSString *lsd = [[MFAntiBan shared] plistPath];
    [out addObject:MK(@"防封目标",
                      lsd ? [lsd stringByReplacingOccurrencesOfString:
                             @"/var/containers/Shared/SystemGroup/" withString:@"…/"]
                          : @"未找到",
                      lsd ? MFEnvStatusPass : MFEnvStatusWarn,
                      @"lsdidentifiers.plist。找不到时防封不可用。"
                      @"首要原因通常是 SystemGroup 对 mobile 不可列（见上面「沙盒豁免」那条）")];

    // ── ⑪ 文件系统 ──
    struct statfs fs;
    NSString *rootInfo = @"不可读";
    if (statfs("/", &fs) == 0) {
        rootInfo = [NSString stringWithFormat:@"%s · 块 %lluK · 可用 %.1fG",
                    fs.f_fstypename,
                    (unsigned long long)(fs.f_bsize / 1024),
                    (double)fs.f_bavail * fs.f_bsize / 1073741824.0];
    }
    [out addObject:MK(@"根文件系统", rootInfo, MFEnvStatusInfo,
                      @"只读挂载是正常的（SSV 密封卷）。清理只动 /var 下的东西。")];

#if DEBUG
    [out addObject:MK(@"构建类型", @"Debug", MFEnvStatusWarn,
                      @"Debug 构建会慢很多，且含调试符号。发布请用 Release。")];
#else
    [out addObject:MK(@"构建类型", @"Release", MFEnvStatusPass,
                      @"已优化，无调试符号。")];
#endif

    self.last = out;
    return out;
}

#pragma mark - 输出

- (NSString *)report {
    NSArray<MFEnvItem *> *items = self.last ?: [self run];
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"复刻版 · 环境检测\n"];
    [s appendString:@"─────────────────────────────\n\n"];
    for (MFEnvItem *i in items) {
        [s appendFormat:@"%@ %@\n", i.symbol, i.name];
        if (i.value.length)  [s appendFormat:@"    %@\n", i.value];
        if (i.detail.length) {
            for (NSString *line in [i.detail componentsSeparatedByString:@"\n"]) {
                [s appendFormat:@"    %@\n", line];
            }
        }
        [s appendString:@"\n"];
    }
    [s appendFormat:@"%@\n", [self summaryLine]];
    return s;
}

- (NSString *)summaryLine {
    NSArray<MFEnvItem *> *items = self.last ?: [self run];
    NSUInteger pass = 0, warn = 0, fail = 0;
    for (MFEnvItem *i in items) {
        if (i.status == MFEnvStatusPass) pass++;
        else if (i.status == MFEnvStatusWarn) warn++;
        else if (i.status == MFEnvStatusFail) fail++;
    }
    NSMutableString *s = [NSMutableString stringWithFormat:
                          @"环境 %lu/%lu 通过", (unsigned long)pass, (unsigned long)items.count];
    if (warn) [s appendFormat:@" · %lu 项警告", (unsigned long)warn];
    if (fail) [s appendFormat:@" · %lu 项不可用", (unsigned long)fail];
    return s;
}

@end
