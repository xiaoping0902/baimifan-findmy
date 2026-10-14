//
//  RootViewController.mm — 主界面控制台
//
//  结构对齐白米饭主界面：状态 / 功能 / 清理与防封 / 系统自检 / 构建信息
//  M0 阶段：全部按钮已接线（未实现的动作弹提示），自检页做 entitlements 实测
//
#import "RootViewController.h"

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
    [s0.rows addObject:[self infoRow:@"内核（KFD）" detail:@"未启动 · M3 接入" ok:NO]];
    [s0.rows addObject:[self infoRow:@"悬浮窗（HUD）" detail:@"未启动 · M2 接入" ok:NO]];
    [s0.rows addObject:[self infoRow:@"运行身份" detail:[self identityText] ok:YES]];
    [secs addObject:s0];

    // ---------- 1 功能 ----------
    MFSection *s1 = [[MFSection alloc] init];
    s1.header = @"功能";
    s1.footer = @"「启动内核」走后端 KFD 链：漏洞 → root → 内核端口 → 枚举全系统 task。";
    [s1.rows addObject:[self actionRow:@"启动内核" detail:@"M3" action:@"actStartKernel"]];
    [s1.rows addObject:[self actionRow:@"内核设置" detail:@"landa / smith / physpuppet / 纯巨魔" action:@"actKernelSettings"]];
    [s1.rows addObject:[self actionRow:@"启动悬浮窗" detail:@"M2" action:@"actStartHUD"]];
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
    [s4.rows addObject:[self infoRow:@"里程碑" detail:@"M0 · 管道 + 伪装壳" ok:YES]];
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
        r.detail = @"✗ 路径不存在"; r.ok = NO; r.hasState = YES; return r;
    }
    NSError *err = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:&err];
    if (!items) {
        r.detail = [NSString stringWithFormat:@"✗ 读取失败：%@", err.localizedDescription ?: @"unknown"];
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
    if (!exe) { r.detail = @"✗ 取不到自身可执行路径"; r.ok = NO; r.hasState = YES; return r; }
    if (access(exe.fileSystemRepresentation, X_OK) != 0) {
        r.detail = [NSString stringWithFormat:@"✗ 无执行权限（errno=%d）", errno];
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

#pragma mark - 动作（M0 桩，后续里程碑填充）

- (void)actStartKernel {
    [self toast:@"内核链将在 M3 接入（kfund patchfinder + landa）"];
}
- (void)actKernelSettings {
    [self toast:@"内核设置页将在 M3 接入"];
}
- (void)actStartHUD {
    [self toast:@"HUD 双窗口将在 M2 接入"];
}
- (void)actCleanResidue {
    [self toast:@"清理系统残留将在 M1 接入（先 dry-run 出清单）"];
}
- (void)actCleanKeychain {
    [self toast:@"清理 Key 将在 M1 接入"];
}
- (void)actAntiBan {
    [self toast:@"防封设置将在 M1 接入"];
}
- (void)actGameMode {
    [self toast:@"高级游戏模式将在 M1 接入"];
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
