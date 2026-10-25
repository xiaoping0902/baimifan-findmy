//
//  RootViewController.mm — 主界面控制台
//
//  结构对齐白米饭主界面：状态 / 功能 / 清理与防封 / 系统自检 / 构建信息
//  M0 阶段：全部按钮已接线（未实现的动作弹提示），自检页做 entitlements 实测
//
#import "RootViewController.h"
#import "MFResidueViewController.h"
#import "MFProcessViewController.h"
#import "../Features/MFPaths.h"
#import "../Features/MFCleanup.h"
#import "../Features/MFKeychain.h"
#import "../Features/MFAntiBan.h"
#import "../Features/MFEnvCheck.h"
#import "../Features/MFModuleExport.h"
#import "../HUD/MFHUDLauncher.h"
#import "../HUD/MFHUDLog.h"
#import "MFDebugExport.h"
#import "../HUD/MFDrawingLayer.h"
#import "../Kernel/MFKernel.h"
#import "../Kernel/MFModuleLocator.h"
#import "../Game/Offsets.h"
#import "../Game/MFUEReader.h"
#import "../Game/MFGameReader.h"
#import "../Read/MFReadBackend.h"   // [M5.15] 一键开始里读门条件用

#import <mach-o/dyld.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

#pragma mark - 行模型

@interface MFRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) BOOL hasState;   // 是否用颜色标状态
@property (nonatomic, assign) BOOL ok;
@property (nonatomic, copy) NSString *action;  // 触发的 selector 名
@end
@implementation MFRow
@end

@interface MFSection : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, strong) NSMutableArray<MFRow *> *rows;
@end
@implementation MFSection
- (instancetype)init {
    if ((self = [super init])) { _rows = [NSMutableArray array]; }
    return self;
}
@end

#pragma mark - 控制台

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, assign) BOOL hudStarting;
@property (nonatomic, assign) BOOL hudStopping;
@property (nonatomic) NSUInteger hudActionGeneration;
@property (nonatomic, strong) NSTimer *hudStatusTimer;
@property (nonatomic) pid_t observedHUDPID;
@property (nonatomic, strong) NSMutableArray<MFSection *> *sections;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"白米饭";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(refreshStatus)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = rc;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hudAppBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatus];
    __weak RootViewController *weakSelf = self;
    [self.hudStatusTimer invalidate];
    self.hudStatusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        RootViewController *owner = weakSelf;
        pid_t pid = [MFHUDLauncher hudPID];
        if (owner && pid != owner.observedHUDPID) [owner refreshStatus];
    }];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.hudStatusTimer invalidate]; self.hudStatusTimer = nil;
}
- (void)hudAppBecameActive:(NSNotification *)notification { [self refreshStatus]; }
- (void)dealloc {
    [self.hudStatusTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 状态刷新 / 建模

- (void)refreshStatus {
    NSMutableArray<MFSection *> *secs = [NSMutableArray array];

    // ---------- 0 状态 ----------
    MFSection *s0 = [[MFSection alloc] init];
    s0.header = @"状态";
    [s0.rows addObject:[self infoRow:@"内核（KFD）" detail:[[MFKernel shared] statusText]
                                  ok:[[MFKernel shared] isOpen]]];

    pid_t currentHUDPID = [MFHUDLauncher hudPID];
    self.observedHUDPID = currentHUDPID;
    BOOL hudUp = currentHUDPID > 0;
    [s0.rows addObject:[self infoRow:@"悬浮窗（HUD）"
                              detail:(hudUp ? [NSString stringWithFormat:@"运行中 · PID %d",
                                               currentHUDPID]
                                            : @"未启动")
                                  ok:hudUp]];
    [s0.rows addObject:[self infoRow:@"运行身份" detail:[self identityText] ok:YES]];

    NSDictionary *rs = [MFCleanup ruleSummary];
    NSString *rulesDetail = ([rs[@"dirs"] unsignedIntegerValue] > 0)
        ? [NSString stringWithFormat:@"%@ 个目录 · 黑 %@ / 白 %@ 条规则",
           rs[@"dirs"], rs[@"blacklistRules"], rs[@"whitelistRules"]]
        : @"配置未加载";
    [s0.rows addObject:[self infoRow:@"清理规则" detail:rulesDetail
                                  ok:([rs[@"dirs"] unsignedIntegerValue] > 0)]];

    NSString *kcMode = [[MFKeychain shared] keychainModeOctal];
    [s0.rows addObject:[self infoRow:@"keychain-2.db"
                              detail:(kcMode ? [NSString stringWithFormat:@"权限 %@ · %@",
                                                kcMode, [[MFKeychain shared] gameModeStatusText]]
                                             : @"不可访问")
                                  ok:(kcMode != nil)]];

    NSString *lsd = [[MFAntiBan shared] plistPath];
    [s0.rows addObject:[self infoRow:@"lsdidentifiers"
                              detail:(lsd ? [lsd stringByReplacingOccurrencesOfString:@"/var/containers/Shared/SystemGroup/" withString:@"…/"]
                                          : @"未找到（防封不可用）")
                                  ok:(lsd != nil)]];
    [secs addObject:s0];

    // ---------- 1 主线（只放真正要点的）----------
    MFSection *s1 = [[MFSection alloc] init];
    s1.header = @"主线";
    s1.footer = @"顺序：开游戏 → 点「启动内核」→ 进进程页自动连上 → 启动悬浮窗。"
                @"内核是唯一可走的路（task_for_pid 已被 PPL 封死）。";
    /*
     * ★ [M5.118] 精简：这一屏只留四个按钮。
     *
     * 用户的反馈很直接："布局很麻烦不简洁"。原来这一节有 11 行，
     * 其中 7 行是排查用的（环境检测/模块定位/UE4 链解析/…），
     * 常态使用一个都用不上，却把主线按钮淹掉了。全部挪到「诊断」里。
     *
     * 另外「★ 一键开始」这行直接删了：它走 task_for_pid，对正版游戏
     * 必然 kr=0x5（PPL 按 CS_HARD 拒），点了只会得到一次失败 —— 留着只会误导。
     */
    [s1.rows addObject:[self actionRow:@"启动内核"
                                detail:@"内核 + 进程自动连接，都在下一页"
                                action:@"actStartKernel"]];
    [s1.rows addObject:[self actionRow:(self.hudStopping ? @"正在结束悬浮窗" :
            (self.hudStarting ? @"取消悬浮窗启动" : (hudUp ? @"结束悬浮窗" : @"启动悬浮窗")))
            detail:(self.hudStarting ? @"正在初始化，点击可取消" : @"菜单、绘制、收起与退出") action:@"actStartHUD"]];
    [s1.rows addObject:[self actionRow:@"HUD 日志" detail:@"悬浮窗从启动到建窗的每一步" action:@"actShowHUDLog"]];
    [s1.rows addObject:[self actionRow:@"导出诊断" detail:@"日志+状态+截图 → Media" action:@"actExportDiagnostics"]];
    [secs addObject:s1];

    // ---------- 1b 诊断（排查时才用）----------
    MFSection *s1b = [[MFSection alloc] init];
    s1b.header = @"诊断";
    s1b.footer = @"平时不用动。每一项都会把结果写进 /var/mobile/Media/mf-debug/。";
    [s1b.rows addObject:[self actionRow:@"内核设置" detail:@"查看/改 PUAF 参数（默认 physpuppet/1024）" action:@"actKernelSettings"]];
    [s1b.rows addObject:[self actionRow:@"环境检测" detail:@"沙盒 / 权限 / fd / 越狱 一次性体检" action:@"actEnvCheck"]];
    [s1b.rows addObject:[self actionRow:@"模块定位" detail:@"找游戏进程 + 取主模块基址" action:@"actLocateModule"]];
    [s1b.rows addObject:[self actionRow:@"UE4 链解析" detail:@"GWorld → 玩家 → 相机 → Actors 逐级验证" action:@"actUEResolve"]];
    [s1b.rows addObject:[self actionRow:@"游戏数据自检" detail:@"读取链 / 偏移 / 投影 状态" action:@"actGameDataCheck"]];
    [s1b.rows addObject:[self actionRow:@"扫描游戏模块"
                                 detail:@"列出游戏 App 里所有 Mach-O：大小 / 架构 / 是否加密"
                                 action:@"actScanGameModules"]];
    [s1b.rows addObject:[self actionRow:@"导出游戏模块"
                                 detail:@"把 libUE4 之类的大模块拷到 Media"
                                 action:@"actExportGameModules"]];
    [secs addObject:s1b];

    // ---------- 2 清理与防封 ----------
    MFSection *s2 = [[MFSection alloc] init];
    s2.header = @"清理与防封";
    s2.footer = @"清理作用于本应用之外的系统目录，执行前会先出扫描清单供确认。";
    [s2.rows addObject:[self actionRow:@"清理系统残留" detail:@"25 个目录 · 黑白名单" action:@"actCleanResidue"]];
    [s2.rows addObject:[self actionRow:@"清理 Key" detail:@"keychain-2.db · 按 agrp 删除" action:@"actCleanKeychain"]];
    [s2.rows addObject:[self actionRow:@"防封设置" detail:@"lsdidentifiers · 4 个腾讯游戏" action:@"actAntiBan"]];
    [s2.rows addObject:[self actionRow:@"高级游戏模式" detail:@"keychain-2.db 权限位" action:@"actGameMode"]];
    [secs addObject:s2];

    // ---------- 3 系统自检（M0 验收）----------
    MFSection *s3 = [[MFSection alloc] init];
    s3.header = @"系统自检（M0 验收）";
    s3.footer = @"用于验证 entitlements 是否在 TrollStore 环境下真实生效。";
    [s3.rows addObject:[self pathRow:@"/var/Keychains" title:@"沙盒豁免 · /var/Keychains"]];
    [s3.rows addObject:[self pathRow:@"/var/mobile" title:@"沙盒豁免 · /var/mobile"]];
    [s3.rows addObject:[self pathRow:@"/Applications" title:@"AppBundles · /Applications"]];
    [s3.rows addObject:[self pathRow:@"/var/containers/Shared/SystemGroup" title:@"防封目标目录可达"]];
    [s3.rows addObject:[self selfSpawnRow]];
    [secs addObject:s3];

    // ---------- 4 构建信息 ----------
    MFSection *s4 = [[MFSection alloc] init];
    s4.header = @"构建信息";
    NSBundle *b = [NSBundle mainBundle];
    [s4.rows addObject:[self infoRow:@"伪装身份"
                              detail:[NSString stringWithFormat:@"%@ / %@",
                                      [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"?",
                                      b.bundleIdentifier ?: @"?"]
                                  ok:YES]];
    [s4.rows addObject:[self infoRow:@"版本"
                              detail:[NSString stringWithFormat:@"%@ (%@)",
                                      [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
                                      [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"]
                                  ok:YES]];
    [s4.rows addObject:[self infoRow:@"构建时间"
                              detail:[NSString stringWithFormat:@"%s  %s", __DATE__, __TIME__]
                                  ok:YES]];
    [s4.rows addObject:[self infoRow:@"里程碑" detail:@"M1 · 控制台 + 清理 / 防封 / 游戏模式" ok:YES]];
    [secs addObject:s4];

    self.sections = secs;
    [self.tableView reloadData];
    [self.tableView.refreshControl endRefreshing];
}

- (MFRow *)infoRow:(NSString *)title detail:(NSString *)detail ok:(BOOL)ok {
    MFRow *r = [MFRow new];
    r.title = title; r.detail = detail; r.ok = ok; r.hasState = YES;
    return r;
}

- (MFRow *)actionRow:(NSString *)title detail:(NSString *)detail action:(NSString *)action {
    MFRow *r = [MFRow new];
    r.title = title; r.detail = detail; r.action = action;
    return r;
}

- (MFRow *)pathRow:(NSString *)path title:(NSString *)title {
    MFRow *r = [MFRow new];
    r.title = title;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        r.detail = @"× 路径不存在"; r.ok = NO; r.hasState = YES; return r;
    }
    NSError *err = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:&err];
    if (!items) {
        r.detail = [NSString stringWithFormat:@"× 读取失败：%@", err.localizedDescription ?: @"unknown"];
        r.ok = NO;
    } else {
        r.detail = [NSString stringWithFormat:@"✓ 可见 %lu 项%@",
                    (unsigned long)items.count, isDir ? @"" : @"（非目录）"];
        r.ok = YES;
    }
    r.hasState = YES;
    return r;
}

/// 实测 posix_spawn 自身（HUD 自派生的前提，M2 要用）
- (MFRow *)selfSpawnRow {
    MFRow *r = [MFRow new];
    r.title = @"自派生能力（posix_spawn）";
    NSString *exe = [NSBundle mainBundle].executablePath;
    if (!exe) { r.detail = @"× 取不到自身可执行路径"; r.ok = NO; r.hasState = YES; return r; }
    if (access(exe.fileSystemRepresentation, X_OK) != 0) {
        r.detail = [NSString stringWithFormat:@"× 无执行权限（errno=%d）", errno];
        r.ok = NO; r.hasState = YES; return r;
    }
    r.detail = @"✓ 可执行文件可访问（未实际拉起子进程）";
    r.ok = YES; r.hasState = YES;
    return r;
}

- (NSString *)identityText {
    struct utsname u;
    NSString *model = @"?";
    if (uname(&u) == 0) model = [NSString stringWithFormat:@"%s", u.machine];
    NSString *ver = [[UIDevice currentDevice] systemVersion] ?: @"?";
    return [NSString stringWithFormat:@"uid=%d gid=%d · iOS %@ · %@",
            getuid(), getgid(), ver, model];
}

#pragma mark - 动作

- (void)actStartKernel {
    MFProcessViewController *vc = [[MFProcessViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)actKernelSettings {
    MFKernel *k = [MFKernel shared];
    NSString *msg = [NSString stringWithFormat:
        @"当前状态：%@\n\n"
        @"身份：%@\n"
        @"可用枚举路由：%@\n\n"
        @"目标机 16.6.1/M2 上唯一可用的组合已固定：\n"
        @"  puaf_method = landa (2)\n"
        @"  kread       = kread_sem_open (1)\n"
        @"  kwrite      = kwrite_sem_open (1)\n"
        @"  puaf_pages  = 2048（不稳可降到 1024/512）\n\n"
        @"详细能力探测请进「启动内核」页点底部「能力探测」。",
        k.statusText, [k identityText],
        k.availableRoute == MFEnumRoutePrivileged ? @"路A（host_priv）"
            : (k.availableRoute == MFEnumRouteDefault ? @"路B（免特权）" : @"未探测")];
    [self alert:@"内核设置" message:msg];
}
- (void)actStartHUD {
    if (self.hudStopping) return;
    if (self.hudStarting) { [self stopHUDNow]; return; }
    if ([MFHUDLauncher isHUDRunning]) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"悬浮窗正在运行"
                             message:[NSString stringWithFormat:@"PID = %d\n\n要结束它吗？",
                                      [MFHUDLauncher hudPID]]
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"结束悬浮窗" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *_) { [self stopHUDNow]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    self.hudStarting = YES;
    NSUInteger generation = ++self.hudActionGeneration;
    [self refreshStatus];
    self.navigationItem.prompt = @"正在等待悬浮窗初始化与首帧，点击列表可取消…";
    [MFHUDLauncher startHUDWithCompletion:^(BOOL ready, NSString *error) {
        if (generation != self.hudActionGeneration) return;
        self.hudStarting = NO;
        self.navigationItem.prompt = nil;
        if (ready) {
            [self alert:@"悬浮窗初始化完成" message:[NSString stringWithFormat:
                @"PID = %d\n\n窗口注册和首帧渲染已完成。\n\n"
                @"· 拖动「标题文字」那一行可以移动整个窗口\n"
                @"·「收起」把小菜单缩成小圆球，点圆球再展开\n"
                @"·「退出」彻底关闭悬浮窗（控制台也会同步显示未运行）\n"
                @"· 操作下层 App 时可先收起，窗口会真正缩小\n"
                @"· 万一菜单没显示，打开「HUD 日志」看现场",
                [MFHUDLauncher hudPID]]];
        } else {
            [self alert:@"悬浮窗启动未完成" message:error ?: @"未知错误，请查看 HUD 日志。"];
        }
        [self refreshStatus];
    }];
}

/*
 * ★ [M5.66] 结束悬浮窗 ★
 *
 * 两处必须改对：
 *
 * ① 原来的 kill(SIGTERM) 对 root 子进程永远 EPERM（控制台是 mobile），
 *    所以这里现在调用的是「通知 + 看门狗 + 兜底」的新链路，
 *    由 HUD 自己执行退出。见 MFHUDLauncher.stopHUDWithError:。
 *
 * ② 新链路最长会等 2~3 秒（先等它自己退，再补信号）。
 *    原来是主线程同步等 —— 会让界面在这几秒里假死，
 *    用户看到的就是「点了没反应」。现在挪到后台队列，界面照常。
 */
- (void)stopHUDNow {
    if (self.hudStopping) return;
    ++self.hudActionGeneration; // Ignore an older startup completion after cancel.
    self.hudStarting = NO; self.hudStopping = YES;
    self.navigationItem.prompt = @"正在确认悬浮窗退出…";
    [self refreshStatus];
    [MFHUDLauncher stopHUDWithCompletion:^(BOOL stopped, NSString *error) {
        self.hudStopping = NO;
        self.navigationItem.prompt = nil;
        [self refreshStatus];
        if (!stopped) [self alert:@"尚未退出" message:error ?: @"身份已保留，可再次点结束。"];
    }];
}

#pragma mark HUD 日志

/// HUD 子进程走一步记一步，落在 Documents/mf_hud.log。
/// 两个进程同沙盒，主进程直接读回来显示。
- (void)actShowHUDLog {
    char *raw = MFHUDLogRead();
    NSString *log = nil;
    if (raw != NULL) {
        log = [NSString stringWithUTF8String:raw];
        free(raw);
    }
    if (log.length == 0) {
        log = @"（还没有 HUD 日志 —— 先点一次「启动悬浮窗」）";
    }

    NSString *pidInfo = [MFHUDLauncher isHUDRunning]
        ? [NSString stringWithFormat:@"HUD 当前 PID = %d", [MFHUDLauncher hudPID]]
        : @"HUD 当前未运行";

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"HUD 日志"
                         message:[NSString stringWithFormat:
                                  @"%@\n\n%@\n\n"
                                  @"排查要点：\n"
                                  @"· starting → 建窗或引导尚未完成\n"
                                  @"· 窗口错误 → context/托管接口未就绪\n"
                                  @"· waiting-for-frames → 等待 Metal 首帧\n"
                                  @"· ready → 注册调用及 GPU 首帧完成，仍需观察屏幕",
                                  pidInfo, log]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"复制全文" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *_) {
        [UIPasteboard generalPasteboard].string = log;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *_) {
        MFHUDLogClear();
        [self alert:@"已清空" message:@"下次「启动悬浮窗」会重新记录"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark task port 分项探测（[M5.78]）

/*
 * 一键开始 ② 失败时，光看一句 "task_for_pid kr=0x5" 没法判断原因。
 * 这里对几个典型进程各试一次，用结果区分两种情况：
 *   · 自己 ✓、游戏 ✗  → 游戏有反调试 / CS_HARD 签名保护，taskgated 拒绝
 *   · 连自己都 ✗      → task_for_pid-allow entitlement 根本没生效
 */
- (NSString *)taskPortProbeReportForGamePid:(pid_t)gamePid {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"分项探测（每个进程都试一次 task_for_pid + processor_set 回退）：\n"];

    NSMutableArray<NSArray *> *probes = [NSMutableArray array];
    [probes addObject:@[@"自己", @(getpid())]];
    [probes addObject:@[@"launchd", @1]];
    pid_t sb = [MFModuleLocator pidForProcessName:@"SpringBoard"];
    if (sb > 0) [probes addObject:@[@"SpringBoard", @(sb)]];
    if (gamePid > 0) [probes addObject:@[@"游戏", @(gamePid)]];

    for (NSArray *entry in probes) {
        NSString *label = entry[0];
        pid_t pid = (pid_t)[entry[1] intValue];
        NSString *e = nil;
        uint32_t port = [MFKernel acquireTaskPortForPid:(int)pid error:&e];
        if (port != MACH_PORT_NULL) {
            [s appendFormat:@"  ✓ %-12@ pid=%-6d task port = 0x%x\n", label, pid, port];
        } else {
            [s appendFormat:@"  ✗ %-12@ pid=%-6d %@\n", label, pid, e ?: @"失败"];
        }
    }

    [s appendString:
        @"\n怎么读：\n"
        @"· 自己 ✓、游戏 ✗ → 游戏有反调试/CS_HARD 保护（ACE 反作弊），"
        @"task_for_pid 被 taskgated 拒，这与 entitlement 无关\n"
        @"· 连「自己」都 ✗ → task_for_pid-allow entitlement 没生效，检查安装方式\n"
        @"· 普通 App ✓、游戏 ✗ → 同上，确认是游戏保护\n"];
    return s;
}

#pragma mark 游戏模块扫描 / 导出（[M5.76]）

/*
 * 为什么在 App 里做这件事：
 *
 *   要补上血量 / 骨骼 / 武器这些字段，必须拿到游戏的 libUE4 模块本体。
 *   它在 /var/containers/Bundle/Application/<UUID>/<App>.app/ 里，
 *   而 AFC 只暴露 /var/mobile/Media —— 电脑侧够不着。
 *
 *   但我们有 no-sandbox + 全盘读权限，所以让 App 自己拷过去最省事：
 *   不用装 Filza、不用 SSH、更不用 frida-ios-dump。
 *
 *   ★ iOS 上 FairPlay 只加密主可执行文件，内嵌的 .framework 是明文 ——
 *     UE 引擎在 iOS 上通常就是独立 framework，所以大概率根本不用脱壳。
 *     扫描报告里的 cryptid 会直接告诉我们答案。
 */
- (void)showCopyableReport:(NSString *)title text:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                             message:text
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"复制全文" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *_) {
        [UIPasteboard generalPasteboard].string = text;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)actScanGameModules {
    NSString *bid = [MFOffsets shared].current.bundleID;
    if (bid.length == 0) bid = @"com.tencent.tmgp.dfm";
    self.navigationItem.prompt = @"正在扫描游戏模块…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = [MFModuleExport scanReportForBundleID:bid];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.prompt = nil;
            [self showCopyableReport:@"游戏模块扫描" text:report];
        });
    });
}

- (void)actExportGameModules {
    NSString *bid = [MFOffsets shared].current.bundleID;
    if (bid.length == 0) bid = @"com.tencent.tmgp.dfm";
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"导出游戏模块"
                         message:[NSString stringWithFormat:
            @"把 %@ 里 32 MB 以上的 Mach-O 模块拷到\n"
            @"  /var/mobile/Media/mf-debug/modules/\n\n"
            @"几百 MB 的模块要几十秒，期间别退出 App。\n\n"
            @"拉取（电脑侧）：\n"
            @"  python -X utf8 -m pymobiledevice3 afc pull /mf-debug/modules <目录>", bid]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"开始导出" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *_) { [self runModuleExport:bid]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runModuleExport:(NSString *)bundleID {
    self.navigationItem.prompt = @"正在导出游戏模块…（大文件会慢，别退出）";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = [MFModuleExport exportModulesForBundleID:bundleID
                                                          minBytes:32ULL * 1024 * 1024];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.prompt = nil;
            [self showCopyableReport:@"游戏模块导出" text:report];
        });
    });
}

#pragma mark 一键开始（纯 TrollStore 模式，不用内核）

/*
 * ★★★ [M5.15] 一键开始 —— 不碰 KFD ★★★
 *
 * ── 为什么这是对的 ──
 *
 * 走查代码确认：整条读取链【完全不依赖 KFD】——
 *     Read/MFReadBackend.mm      KFD 相关 0 处 / task-port 相关 13 处
 *     Game/MFGameReader.mm       KFD 相关 0 处 / task-port 相关  4 处
 *     Kernel/MFModuleLocator.mm  KFD 相关 0 处（只有 import）/ task-port 7 处
 *
 * 门条件也只认 task port：
 *     gateOpen = modeFlag && targetTaskPort != MACH_PORT_NULL
 *
 * 而 task port 来自 task_for_pid —— 靠 task_for_pid-allow entitlement
 * （从设备读出核对过，7 项权限全部生效）。
 *
 * ── 为什么必须绕开 KFD ──
 *
 * 真机已经付过代价：
 *   · panic(cpu 5): pmap_map_cpu_windows_copy_internal:
 *         attempted to map a managed page @pmap.c:10917
 *     —— vm_copy 碰到 KFD 制造的悬空页时的典型后果
 *   · App SIGSEGV 在 objc_autoreleasePoolPop
 *     —— 悬空页被系统挪作他用，我们还在碰 → 内存破坏
 *   · 而且 landa 的竞态是概率性的：成过一次（截图有「启动成功 puaf_pages=3072」），
 *     但 6 次重试 6 次 0/768
 *
 * 这正是白米饭留「纯巨魔模式」的原因。
 *
 * ── 一键做什么 ──
 *   ① 按进程名找游戏进程（sysctl KERN_PROC_ALL）
 *   ② task_for_pid 拿 task port
 *   ③ 模块定位（TASK_DYLD_INFO → libUE4 基址）
 *   ④ UE4 链解析（GWorld → 玩家 → 相机 → Actors）
 * 每一步都写在报告里，断在哪一环一目了然。
 */
- (void)actOneClick {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *rep = [NSMutableString string];
        /*
         * ★ [M5.87] 标题改过。原来只有"（纯 TrollStore，不用内核）"这几个字，
         * 用户看到"② 拿不到 task port"时会以为是自己操作错了或者版本有问题。
         * 实际上这个模式**必然失败**——它不碰 KFD，而 task_for_pid 已被 PPL 封死。
         * 所以标题里就要把这件事说清楚，并直接指向正确按钮。
         */
        [rep appendString:@"复刻版 · 一键开始（纯 TrollStore 模式）\n"];
        [rep appendString:@"─────────────────────────────────\n"];
        [rep appendString:@"⚠️ 本模式不调用 KFD。task_for_pid 已被内核 PPL 封死，\n"];
        [rep appendString:@"   所以下面第 ② 步必然失败——这是预期结果，不是你操作错了。\n"];
        [rep appendString:@"   要真正读游戏数据，请先回功能页点「启动内核」。\n"];
        [rep appendString:@"─────────────────────────────────\n\n"];

        MFGameProfile *prof = [MFOffsets shared].current;
        NSString *pname = prof.processName.length ? prof.processName : @"DeltaForceClient";
        [rep appendFormat:@"目标游戏：%@（进程名 %@）\n\n", prof.displayName, pname];

        // ① 找进程
        pid_t gpid = [MFModuleLocator pidForProcessName:pname];
        if (gpid <= 0) {
            [rep appendFormat:
                @"✗ ① 没找到进程「%@」\n\n"
                @"请先打开「%@」并进到游戏里，再回来点这里。\n",
                pname, prof.displayName];
            goto done;
        }
        [rep appendFormat:@"✓ ① 找到进程 pid=%d\n", gpid];

        // ② 拿 task port
        {
            NSString *perr = nil;
            uint32_t port = [MFKernel acquireTaskPortForPid:(int)gpid error:&perr];
            if (port == MACH_PORT_NULL) {
                [rep appendFormat:@"✗ ② 拿不到 task port：%@\n\n", perr ?: @"?"];
                [rep appendString:[self taskPortProbeReportForGamePid:gpid]];
                goto done;
            }
            [MFGameReader shared].targetTaskPort = port;
            [[MFReadBackend shared] setTargetTaskPort:port];
            [[NSUserDefaults standardUserDefaults] setInteger:gpid forKey:@"mf.target.pid"];
            [[NSUserDefaults standardUserDefaults] setObject:pname forKey:@"mf.target.name"];
            [rep appendFormat:@"✓ ② task port = 0x%x，读取链门条件=%d\n",
                port, [MFReadBackend shared].gateOpen];
        }

        // ③ 模块定位
        {
            NSString *merr = nil;
            MFModuleInfo *m = [MFModuleLocator mainModuleForPid:gpid error:&merr];
            if (m == nil) {
                [rep appendFormat:@"✗ ③ 模块定位失败：%@\n", merr ?: @"?"];
                goto done;
            }
            [MFUEReader shared].libBase = m.base;
            [[NSUserDefaults standardUserDefaults] setObject:@(m.base) forKey:@"mf.game.libbase"];
            [[NSUserDefaults standardUserDefaults] setObject:m.name forKey:@"mf.game.module"];
            [rep appendFormat:@"✓ ③ 主模块 %@  base=0x%llx  %@\n",
                m.name, m.base, [m sizeText]];
        }

        // ④ UE4 链解析
        {
            [rep appendString:@"\n④ UE4 对象图逐级解析：\n"];
            NSString *ue = [[MFUEReader shared] diagnosticReport];
            // 缩进一下，读起来清楚
            for (NSString *line in [ue componentsSeparatedByString:@"\n"]) {
                if (line.length) [rep appendFormat:@"    %@\n", line];
            }
        }

    done:
        [rep appendString:@"\n─────────────────────────────────\n"];
        [rep appendString:@"此诊断不调用 KFD；游戏数据链仍需逐级验证。\n"];
        [rep appendString:@"如果 ④ 报「GWorld 不是合法指针」，说明 0x178B44E0\n"];
        [rep appendString:@"这个静态偏移已经随游戏版本失效，需要用扫描重新定位。\n"];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"一键开始"
                                 message:rep
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制全文"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = rep;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark UE4 链解析

/// 走 UE4 标准对象图：GWorld → GameInstance → LocalPlayers → PlayerController
///   → Pawn / CameraManager → PlayerState(队伍) → ULevel → Actors[]
///
/// 依据 mingyun 2.0.4 的反编译（RefreshControllerChain @ 0x100010b3c /
/// GetEnemyThread @ 0x100010c0c / ESPReadMeshWorldPos @ 0x1000118ac）。
/// 逐级验证，断在哪一环会明确写出来。
- (void)actUEResolve {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MFUEReader *ur = [MFUEReader shared];

        // ASLR addresses belong to one running game instance. Resolve afresh
        // rather than restoring an unscoped absolute address from defaults.
        NSString *pname = [MFOffsets shared].current.processName;
        MFModuleInfo *module = pname.length ? [MFModuleLocator locateProcess:pname error:NULL] : nil;
        ur.libBase = module ? module.base : 0;

        NSString *rep = [ur diagnosticReport];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"UE4 链解析"
                                 message:rep
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = rep;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark 模块定位

/// 从「进程名」一路拿到「模块加载基址」—— UE4 对象图的起点。
///
/// 为什么必须有它：UE4 的一切都是「模块基址 + 固定偏移」，例如
///     GWorld = Read<u64>(sLibBase + 0x178B44E0);
/// 白米饭用一个全局变量存这个基址（原地址 0x100FF65D0），
/// 那个全局的写入点在静态分析里没查到 —— 现在清楚了：它存的就是模块基址。
- (void)actLocateModule {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MFGameProfile *prof = [MFOffsets shared].current;
        NSString *pname = prof.processName;
        NSMutableString *out = [NSMutableString string];

        if (pname.length == 0) {
            [out appendFormat:@"当前档案「%@」没有进程名，无法定位。\n", prof.displayName];
        } else {
            NSError *e = nil;
            NSString *err = nil;
            MFModuleInfo *m = [MFModuleLocator locateProcess:pname error:&err];
            [out appendFormat:@"%@\n\n", [MFModuleLocator lastReport]];
            if (m) {
                [out appendFormat:
                    @"★ 模块基址 = 0x%llx\n\n"
                    @"这个值就是 UE4 链的起点 sLibBase。\n"
                    @"下一步该做的是「UE4 对象图读取」——\n"
                    @"    GWorld = Read(sLibBase + 0x178B44E0)\n",
                    m.base];
                // 存下来，供后续 UE4 读取用
                [[NSUserDefaults standardUserDefaults] setObject:@(m.base) forKey:@"mf.game.libbase"];
                [[NSUserDefaults standardUserDefaults] setObject:m.name forKey:@"mf.game.module"];
                pid_t gpid = [MFModuleLocator pidForProcessName:pname];
                [[NSUserDefaults standardUserDefaults] setInteger:gpid forKey:@"mf.game.pid"];
                // ★ 直接接进 UE4 读取器 —— 不用再手动填
                [MFUEReader shared].libBase = m.base;
                NSLog(@"[MF][Module] 已把 libBase=0x%llx 交给 MFUEReader", m.base);
            } else {
                [out appendFormat:@"✗ 定位失败：%@\n", err ?: @"未知"];
            }
            (void)e;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"模块定位"
                                 message:out
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = out;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark 环境检测

/// 对照原版「高级设置 → 环境检测」。
/// 把「为什么某个功能不好使」的原因一次性列出来 —— 装机后第一件事就该跑它。
- (void)actEnvCheck {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *rep = [[MFEnvCheck shared] report];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"环境检测"
                                 message:rep
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制报告"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = rep;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark 导出诊断

/// 把日志 + 状态快照 + 自截图写到 /var/mobile/Media/mf-debug/
/// 那边 AFC 直接能读 —— 电脑上一条 `python scripts/dev.py pull` 就拉走，
/// 不用再靠「弹窗显示 + 手动复制」。
- (void)actExportDiagnostics {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *summary = [MFDebugExport exportAll];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"导出诊断"
                                 message:summary
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制结果"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = summary;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark 游戏数据自检

- (void)actGameDataCheck {
    CGSize sz = self.view.bounds.size;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *dump = nil;
        if ([MFGameReader shared].ready) {
            MFDrawingLayer *dl = [[MFDrawingLayer alloc] init];
            dump = [dl dumpFrameWithSize:sz];
        } else {
            dump = [NSString stringWithFormat:
                    @"读取链未就绪\n\n%@\n\n"
                    @"要打开读取链：\n"
                    @"1) 进「启动内核」页\n"
                    @"2) 底部「能力探测」→ 拿到进程列表\n"
                    @"3) 点目标游戏的进程 → 自动绑定 task port",
                    [[MFGameReader shared] diagnosticReport]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"游戏数据自检"
                                                                      message:dump
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = dump;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark 清理系统残留

- (void)actCleanResidue {
    MFResidueViewController *vc = [[MFResidueViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark 清理 Key

- (void)actCleanKeychain {
    NSArray<NSString *> *games = [MFKeychain gameBundleIDs];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"清理 Key"
                         message:@"打开 /var/Keychains/keychain-2.db，按 agrp 字段 LIKE 匹配 bundleID 并删除条目。\n\n先选一个目标统计（不会立即删除）："
                  preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = self.view.bounds;
    [a addAction:[UIAlertAction actionWithTitle:@"四个游戏全部统计" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *_) { [self keychainCountAll]; }]];
    for (NSString *g in games) {
        [a addAction:[UIAlertAction actionWithTitle:g style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *_) { [self keychainCountOne:g]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)keychainCountAll {
    NSMutableString *msg = [NSMutableString string];
    NSInteger total = 0;
    for (MFKeychainResult *r in [[MFKeychain shared] countForAllGames]) {
        if (r.error) { [msg appendFormat:@"%@\n  × %@\n", r.bundleID, r.error]; continue; }
        [msg appendFormat:@"%@\n  命中 %ld 条\n", r.bundleID, (long)r.totalMatched];
        total += r.totalMatched;
    }
    [msg appendFormat:@"\n合计 %ld 条", (long)total];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"统计结果" message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    if (total > 0) {
        [a addAction:[UIAlertAction actionWithTitle:@"删除全部" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *_) { [self keychainDeleteAll]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)keychainCountOne:(NSString *)bundleID {
    MFKeychainResult *r = [[MFKeychain shared] countForBundleID:bundleID];
    if (r.error) { [self toast:r.error]; return; }

    NSMutableString *msg = [NSMutableString stringWithFormat:@"%@\n命中 %ld 条\n", bundleID, (long)r.totalMatched];
    for (NSString *t in r.matchedPerTable) {
        [msg appendFormat:@"  %@: %@\n", t, r.matchedPerTable[t]];
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"统计结果" message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    if (r.totalMatched > 0) {
        [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *_) { [self keychainDeleteOne:bundleID]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)keychainDeleteAll {
    NSMutableString *msg = [NSMutableString string];
    NSInteger total = 0;
    for (MFKeychainResult *r in [[MFKeychain shared] countForAllGames]) {
        total += r.totalMatched;
    }
    for (NSString *g in [MFKeychain gameBundleIDs]) {
        MFKeychainResult *r = [[MFKeychain shared] deleteForBundleID:g];
        [msg appendFormat:@"%@: 删除 %ld 条\n", g, (long)r.totalDeleted];
    }
    [msg insertString:[NSString stringWithFormat:@"共 %ld 条\n\n", (long)total] atIndex:0];
    [self alert:@"清理 Key 完成" message:msg];
    [self refreshStatus];
}

- (void)keychainDeleteOne:(NSString *)bundleID {
    MFKeychainResult *r = [[MFKeychain shared] deleteForBundleID:bundleID];
    [self alert:@"清理 Key 完成"
        message:[NSString stringWithFormat:@"%@\n删除 %ld 条", bundleID, (long)r.totalDeleted]];
    [self refreshStatus];
}

#pragma mark 防封

- (void)actAntiBan {
    MFAntiBan *ab = [MFAntiBan shared];
    NSString *path = [ab plistPath];
    if (!path) { [self toast:@"未找到 com.apple.lsdidentifiers.plist"]; return; }

    [ab backupPlistWithError:NULL];      // 先备份

    NSDictionary *dump = [ab dumpStructure];
    NSMutableString *msg = [NSMutableString stringWithFormat:@"文件：\n%@\n\n顶层结构：\n", path];
    for (NSString *k in dump) {
        if ([k isEqualToString:@"path"]) continue;
        [msg appendFormat:@"  %@ → %@\n", k, dump[k]];
    }

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"防封 · LaunchServices 标识符"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"重置四个游戏" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *_) { [self antiBanReset]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)antiBanReset {
    NSString *err = nil;
    NSDictionary<NSString *, NSString *> *map =
        [[MFAntiBan shared] resetIdentifiersForGamesWithError:&err];
    if (err) { [self toast:err]; return; }

    NSMutableString *msg = [NSMutableString stringWithFormat:@"已重置 %lu 个目标的标识符：\n\n",
                            (unsigned long)map.count];
    for (NSString *k in map) {
        [msg appendFormat:@"%@\n  %@\n", k, map[k]];
    }
    [msg appendString:@"\n原文件已备份到 App 的 Documents 目录。"];
    [self alert:@"防封完成" message:msg];
}

#pragma mark 高级游戏模式

- (void)actGameMode {
    MFKeychain *kc = [MFKeychain shared];
    NSString *status = [kc gameModeStatusText];
    BOOL on = [kc isGameModeOn];

    NSString *warn =
        @"纯巨魔模式重启概率高不建议开启\n"
        @"开启高级游戏模式\n"
        @"可解决设备黑环境问题\n"
        @"一定记得关闭\n"
        @"1.有人反馈开启后关机重启会白\n"
        @"2.多人反馈不会白没问题\n"
        @"自行考虑是否开启";

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"高级游戏模式"
                         message:[NSString stringWithFormat:@"%@\n\n%@", status, warn]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:(on ? @"关闭" : @"开启")
                                          style:(on ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                        handler:^(UIAlertAction *_) { [self gameModeToggle:!on]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)gameModeToggle:(BOOL)on {
    NSString *err = nil;
    if (![[MFKeychain shared] setGameModeOn:on error:&err]) {
        [self toast:[NSString stringWithFormat:@"切换失败：%@\n\n（需要 root 权限）", err]];
        return;
    }
    [self alert:@"已切换" message:[[MFKeychain shared] gameModeStatusText]];
    [self refreshStatus];
}

#pragma mark - 小工具

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"尚未接入"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sections[s].header;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.sections[s].footer;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[s].rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"mfcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        cell.detailTextLabel.numberOfLines = 0;
    }
    MFRow *row = self.sections[ip.section].rows[ip.row];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.detail;

    if (row.action.length) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = [UIColor labelColor];
        if (row.hasState) {
            cell.detailTextLabel.textColor = row.ok
                ? [UIColor systemGreenColor]
                : [UIColor systemOrangeColor];
        } else {
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MFRow *row = self.sections[ip.section].rows[ip.row];
    if (!row.action.length) return;
    SEL sel = NSSelectorFromString(row.action);
    if ([self respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:sel];
#pragma clang diagnostic pop
    }
}

@end
