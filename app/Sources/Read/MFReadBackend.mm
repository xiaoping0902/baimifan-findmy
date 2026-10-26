//
//  MFReadBackend.mm — 跨进程内存读取后端（实现）
//
#import "MFReadBackend.h"
#import "../Kernel/MFKernelBridge.h"
#import "../Kernel/MFPageTable.h"
#import <mach/mach.h>
#import <dlfcn.h>
#import <unistd.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <string.h>

// [M5.207] mach_vm_remap / mach_vm_deallocate 已随端口路一起移除：
// 读取只走 KFD 页表，不再需要把目标页映射进本进程。

/// 进程实例身份：pid | 可执行路径 | 启动秒 | 启动微秒。
///
/// 只用 pid 不能区分"同一 pid 被系统复用"，而 task port 已经从会话标识里
/// 退场，所以这里显式带上路径与启动时间，和 HUD 侧的 MFTargetIdentity 同构。
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
static NSString *MFReadSessionIdentityForPid(int pid) {
    if (pid <= 0) return nil;
    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    path[sizeof(path) - 1] = '\0';
    NSString *executable = [NSString stringWithUTF8String:path];
    if (executable.length == 0) return nil;

    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {0};
    size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length != sizeof(info) ||
        info.kp_proc.p_pid != pid || info.kp_proc.p_starttime.tv_sec <= 0) return nil;
    return [NSString stringWithFormat:@"%d|%@|%lld|%d", pid, executable,
            (long long)info.kp_proc.p_starttime.tv_sec,
            (int)info.kp_proc.p_starttime.tv_usec];
}

@implementation MFReadBackend {
    uint64_t _readCount;
    uint64_t _failCount;
    uint64_t _observedWorld;
    int _identityPid;           // sessionIdentity 缓存对应的 pid
    NSString *_identityCache;   // sessionIdentity 的惰性缓存
}

+ (instancetype)shared {
    static MFReadBackend *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFReadBackend alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _modeFlag = NO;
        _targetTaskPort = MACH_PORT_NULL;
        NSLog(@"[MF][Read] 后端就绪：仅 KFD 页表直读（端口路已在 M5.207 移除）");
    }
    return self;
}

#pragma mark - 门条件

- (BOOL)gateOpen {
    // [M5.207] 端口路移除后，门只看"KFD 根表是否就位"。
    // 原实现在这里是 modeFlag && 端口 != 0 —— 那个端口对 App Store 正版
    // 游戏永远拿不到，本来就只是历史包袱。
    return self.modeFlag && self.kfdRoot != 0;
}

/*
 * [M5.117] 把读取后端切到 KFD 页表直读。
 *
 * [M5.207] 这已经是**唯一**的读取路径：原来的 mach_vm_remap + 目标 task port
 * 分支被整体删除。理由见头文件：端口路要求先 task_for_pid，而那条路既拿不到
 * （正版游戏 CS_HARD 拒绝），又会在目标进程上留下被持有的端口和改过的 csflags。
 *
 * 现在：pid → pmap 根表（mf_pid_chain），之后每个 readRemote 都用 mfpt_read
 * 走目标自己的页表，完全不碰 task port。
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
        self.modeFlag = NO;
        _sessionIdentity = nil;
        return NO;
    }
    self.kfdPid = pid;
    self.kfdRoot = root;
    self.modeFlag = YES;
    mfpt_cache_reset();
    NSLog(@"[MF][Read] KFD 后端就绪 pid=%d root=0x%llx session=%@",
          pid, (unsigned long long)root, self.sessionIdentity ?: @"(身份未确认)");
    return YES;
}

- (void)detachKFD {
    self.kfdRoot = 0;
    self.kfdPid = 0;
    self.modeFlag = NO;
    _identityPid = 0;
    _identityCache = nil;
    mfpt_cache_reset();
}

/*
 * 会话身份按当前 kfdPid **惰性**计算。
 *
 * 为什么不在 attach 时算死：会话身份是"这个后端现在指向哪个进程实例"的纯函数。
 * 绑定时算死会让任何直接设置 kfdPid 的路径（回归夹具、诊断）拿不到身份，
 * 而身份缺失会让基址快照被拒绝保存 —— 测试就只能造出一个"永远没有身份"的后端，
 * 验证不了真正要验证的分支。
 */
- (NSString *)sessionIdentity {
    const int pid = self.kfdPid;
    if (pid <= 0) return nil;
    if (_identityPid == pid && _identityCache) return _identityCache;
    _identityPid = pid;
    _identityCache = MFReadSessionIdentityForPid(pid);
    return _identityCache;
}

- (uint64_t)sessionToken {
    if (self.kfdRoot == 0) return 0;
    // FNV-1a over the identity string, mixed with the pmap root:
    // 同一 pid 重启后 identity 变（启动时间不同），令牌随之改变。
    uint64_t h = 1469598103934665603ULL;
    NSString *s = self.sessionIdentity;
    for (NSUInteger i = 0; i < s.length; i++) {
        h ^= (uint64_t)[s characterAtIndex:i];
        h *= 1099511628211ULL;
    }
    h ^= self.kfdRoot;
    // [M5.209] 换局也要换令牌：世界指针变过就把世代折进来，
    // 让物品表 / 装备表 / 名字表跟着作废（同一进程、不同一局）。
    h ^= (_matchEpoch * 0x9E3779B97F4A7C15ULL);
    return h ? h : 1;   // 0 预留给"未绑定"
}

- (void)noteWorldPointer:(uint64_t)world {
    // 只接受用户态合法指针：换局瞬间读到 0 / 半初始化值不算换局
    if (world < 0x100000001ULL || world >= 0x2F00000000ULL) return;
    if (_observedWorld == 0) {
        _observedWorld = world;      // 第一次见到世界指针：只记世代基线
        return;
    }
    if (world == _observedWorld) return;
    _observedWorld = world;
    _matchEpoch += 1;
    NSLog(@"[MF][Read] 对局切换：世界指针 → 0x%llx，世代 %llu（会话缓存作废）",
          (unsigned long long)world, (unsigned long long)_matchEpoch);
}

- (void)setTargetTaskPort:(uint32_t)port {
    // [M5.207] 端口槽位只保留给旧调用点写值：不参与门判、不参与读取。
    // 读取门现在由 attachKFDPid 打开，这里只记录并告警，避免"设了端口却以为门开了"。
    _targetTaskPort = MACH_PORT_NULL;
    if (port != MACH_PORT_NULL) {
        NSLog(@"[MF][Read] 忽略 task port 0x%x：端口路已移除，读取只在 KFD 路径上成立", port);
    }
}

#pragma mark - 底层读取

- (BOOL)readRemote:(uint64_t)remote into:(void *)out size:(size_t)size {
    if (!out || size == 0) return NO;

    /*
     * [M5.207] 只剩 KFD 页表直读这一条腿。
     * 没有 pmap 根表 = 没绑定目标，直接失败；不再回退到 mach_vm_remap，
     * 因为那条路要 task port，而端口路已经整体移除。
     */
    if (self.kfdRoot == 0) {
        _failCount++;
        return NO;
    }
    uint64_t translated = 0;
    if (mfpt_translate(self.kfdRoot, remote, &translated) == 0) {
        _readCount++;
        return mfpt_read(self.kfdRoot, remote, out, size) == 0;
    }
    _failCount++;
    return NO;
}

- (size_t)readRemotePartial:(uint64_t)remote into:(void *)out size:(size_t)size {
    if (!out || size == 0) return 0;

    if (self.kfdRoot != 0) {
        size_t got = 0;
        int rc = mfpt_read_partial(self.kfdRoot, remote, out, size, &got);
        if (rc == 0 && got > 0) {
            _readCount++;
            return got;
        }
        _failCount++;
        return got;
    }

    return [self readRemote:remote into:out size:size] ? size : 0;
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
    return [NSString stringWithFormat:@"读取 %llu 次 · 失败 %llu 次 · 成功率 %.1f%%\n门：%@ · KFD root %#llx · 会话 %@",
            _readCount, _failCount, rate,
            self.gateOpen ? @"开" : @"关", (unsigned long long)self.kfdRoot,
            self.sessionIdentity ?: @"(未绑定)"];
}

- (void)resetStats {
    _readCount = 0;
    _failCount = 0;
}

@end
