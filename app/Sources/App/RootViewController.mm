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
#import "../HUD/MFHUDLauncher.h"
#import "../HUD/MFHUDLog.h"
#import "MFDebugExport.h"
#import "../HUD/MFDrawingLayer.h"
#import "../Kernel/MFKernel.h"
#import "../Kernel/MFModuleLocator.h"
#import "../Game/Offsets.h"
#import "../Game/MFUEReader.h"
#import "../Game/MFGameReader.h"

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
@property (nonatomic, strong) NSMutableArray<MFSection *> *sections;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"复刻版 · 控制台";
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

    [self refreshStatus];
}

#pragma mark - 状态刷新 / 建模

- (void)refreshStatus {
    NSMutableArray<MFSection *> *secs = [NSMutableArray array];

    // ---------- 0 状态 ----------
    MFSection *s0 = [[MFSection alloc] init];
    s0.header = @"状态";
    [s0.rows addObject:[self infoRow:@"内核（KFD）" detail:[[MFKernel shared] statusText]
                                  ok:[[MFKernel shared] isOpen]]];

    BOOL hudUp = [MFHUDLauncher isHUDRunning];
    [s0.rows addObject:[self infoRow:@"悬浮窗（HUD）"
                              detail:(hudUp ? [NSString stringWithFormat:@"运行中 · PID %d",
                                               [MFHUDLauncher hudPID]]
                                            : @"未启动 · M2 已接入")
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

    // ---------- 1 功能 ----------
    MFSection *s1 = [[MFSection alloc] init];
    s1.header = @"功能";
    s1.footer = @"「启动内核」走后端 KFD 链：漏洞 → root → 内核端口 → 枚举全系统 task。";
    [s1.rows addObject:[self actionRow:@"启动内核" detail:@"M3" action:@"actStartKernel"]];
    [s1.rows addObject:[self actionRow:@"内核设置" detail:@"landa / smith / physpuppet / 纯巨魔" action:@"actKernelSettings"]];
    [s1.rows addObject:[self actionRow:@"启动悬浮窗" detail:@"M2" action:@"actStartHUD"]];
    [s1.rows addObject:[self actionRow:@"HUD 日志" detail:@"子进程从 main() 到建窗的每一步" action:@"actShowHUDLog"]];
    [s1.rows addObject:[self actionRow:@"导出诊断" detail:@"日志+状态+截图 → Media，电脑一条命令拉走" action:@"actExportDiagnostics"]];
    [s1.rows addObject:[self actionRow:@"环境检测" detail:@"沙盒/权限/fd/越狱/内核链 一次性体检" action:@"actEnvCheck"]];
    [s1.rows addObject:[self actionRow:@"模块定位" detail:@"找游戏进程 + 取主模块基址（UE4 链的起点）" action:@"actLocateModule"]];
    [s1.rows addObject:[self actionRow:@"UE4 链解析" detail:@"GWorld → 玩家 → 相机 → Actors 逐级验证" action:@"actUEResolve"]];
    [s1.rows addObject:[self actionRow:@"游戏数据自检" detail:@"读取链 / 偏移 / 投影 状态" action:@"actGameDataCheck"]];
    [secs addObject:s1];

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

    NSString *err = nil;
    if (![MFHUDLauncher startHUDWithError:&err]) {
        [self alert:@"启动失败" message:[NSString stringWithFormat:
            @"%@\n\n排查建议：\n"
            @"1) 自检页里 /var/mobile 是否可读\n"
            @"2) 控制台日志里找 [MF][HUDLaunch]", err ?: @"未知错误"]];
        return;
    }
    [self alert:@"悬浮窗已启动"
        message:[NSString stringWithFormat:
                 @"HUD 进程 PID = %d\n\n"
                 @"它会在 0.35 秒后把两个窗口托管给 SpringBoard。\n"
                 @"若没看到悬浮菜单，去看设备日志里的 [MF][HUD] 行。",
                 [MFHUDLauncher hudPID]]];
    [self refreshStatus];
}

- (void)stopHUDNow {
    NSString *err = nil;
    if (![MFHUDLauncher stopHUDWithError:&err]) {
        [self alert:@"结束失败" message:err ?: @"未知错误"];
    }
    [self refreshStatus];
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
                                  @"· 只有「main() 进入，角色判定并启动 HUD」→ 子进程没到 didFinish\n"
                                  @"· 有 didFinish 但没有「托管前诊断」→ 卡在建窗\n"
                                  @"· windowScene=nil / _contextId=nil → 窗口没进合成器\n"
                                  @"· applicationState=2 → 子进程被当成后台，拿不到场景",
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

        // 如果还没定位过模块，先自动做一次
        if (ur.libBase == 0) {
            NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"mf.game.libbase"];
            if (saved) {
                ur.libBase = [saved unsignedLongLongValue];
            } else {
                NSString *pname = [MFOffsets shared].current.processName;
                MFModuleInfo *m = pname.length ? [MFModuleLocator locateProcess:pname error:NULL] : nil;
                if (m) ur.libBase = m.base;
            }
        }

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
///     GWorld = Read<u64>(sLibBase + 0x178AA5E0);
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
                    @"    GWorld = Read(sLibBase + 0x178AA5E0)\n",
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
