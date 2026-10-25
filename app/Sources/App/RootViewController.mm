//
//  RootViewController.mm — 主界面（极简）
//
//  ★ [M5.173] 精简：这个 App 现在只做一件事 —— 把悬浮窗拉起来。
//
//  为什么砍掉原来的五大节：
//    菜单、绘制、开关、收起/退出全在悬浮窗自己身上，主界面里那些
//    「启动内核 / 内核设置 / 环境检测 / 模块定位 / UE4 链解析 / 游戏数据自检 /
//      扫描模块 / 导出模块 / 清理残留 / 清理 Key / 防封 / 高级游戏模式 /
//      系统自检 / 导出诊断」全是排查期的一次性工具，常态使用一个都用不到，
//      还把唯一的「启动悬浮窗」淹在下拉十几行里。
//
//  现在只有三节：状态 / 操作 / 关于。
//

#import "RootViewController.h"
#import "../HUD/MFHUDLauncher.h"
#import "../HUD/MFHUDLog.h"

#include <stdlib.h>     /* free —— MFHUDLogRead 返回的缓冲区要自己释放 */

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

#pragma mark - 主界面

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

    self.title = @"小玉";
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

#pragma mark - 建模（只有三节）

- (void)refreshStatus {
    NSMutableArray<MFSection *> *secs = [NSMutableArray array];

    // ---------- 状态 ----------
    MFSection *s0 = [[MFSection alloc] init];
    s0.header = @"状态";

    pid_t pid = [MFHUDLauncher hudPID];
    self.observedHUDPID = pid;
    BOOL hudUp = pid > 0;
    [s0.rows addObject:[self infoRow:@"悬浮窗"
                              detail:(hudUp ? [NSString stringWithFormat:@"运行中 · PID %d", pid]
                                            : (self.hudStarting ? @"正在启动…" : @"未启动"))
                                  ok:hudUp]];
    s0.footer = hudUp ? @"菜单、开关、收起都在悬浮窗上，直接点它就行。"
                      : @"点下面的「启动悬浮窗」，然后打开游戏，它会自己接上。";
    [secs addObject:s0];

    // ---------- 操作 ----------
    MFSection *s1 = [[MFSection alloc] init];
    s1.header = @"操作";
    NSString *title = self.hudStopping ? @"正在结束悬浮窗"
                    : (self.hudStarting ? @"取消启动"
                    : (hudUp ? @"结束悬浮窗" : @"启动悬浮窗"));
    [s1.rows addObject:[self actionRow:title
                               detail:(self.hudStarting ? @"正在初始化，点这里可以取消"
                                       : (hudUp ? @"彻底关掉悬浮窗，内核一起释放"
                                                : @"拉起悬浮窗（内核在它里面开）"))
                                action:@"actStartHUD"]];
    [secs addObject:s1];

    // ---------- 关于 ----------
    MFSection *s2 = [[MFSection alloc] init];
    s2.header = @"关于";
    NSBundle *b = [NSBundle mainBundle];
    [s2.rows addObject:[self infoRow:@"版本"
                              detail:[NSString stringWithFormat:@"%@ (%@) · %@",
                                      [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
                                      [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
                                      [b objectForInfoDictionaryKey:@"MFBuildStamp"] ?: @"未注入"]
                                  ok:YES]];
    [s2.rows addObject:[self actionRow:@"HUD 日志" detail:@"悬浮窗从启动到建窗每一步（排除故障时看）"
                                action:@"actShowHUDLog"]];
    [secs addObject:s2];

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

#pragma mark - 动作

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
            [self alert:@"悬浮窗已就绪" message:[NSString stringWithFormat:
                @"PID = %d\n\n"
                @"· 拖动「标题文字」那一行可以移动整个窗口\n"
                @"·「收起」把它缩成小圆球，点圆球再展开\n"
                @"·「退出」彻底关闭（这里也会同步显示未运行）\n"
                @"· 万一菜单没显示，看「HUD 日志」", [MFHUDLauncher hudPID]]];
        } else {
            [self alert:@"悬浮窗启动未完成" message:error ?: @"未知错误，请看「HUD 日志」。"];
        }
        [self refreshStatus];
    }];
}

/*
 * 结束悬浮窗：先让它自己走（通知 + 看门狗），再由调用方补信号。
 * 全程在后台队列里等，主线程不阻塞 —— 否则界面会假死几秒。
 */
- (void)stopHUDNow {
    if (self.hudStopping) return;
    ++self.hudActionGeneration; // 忽略更早那次启动的完成回调
    self.hudStarting = NO; self.hudStopping = YES;
    self.navigationItem.prompt = @"正在确认悬浮窗退出…";
    [self refreshStatus];
    [MFHUDLauncher stopHUDWithCompletion:^(BOOL stopped, NSString *error) {
        self.hudStopping = NO;
        self.navigationItem.prompt = nil;
        [self refreshStatus];
        if (!stopped) [self alert:@"尚未退出" message:error ?: @"身份已保留，可再点一次结束。"];
    }];
}

#pragma mark - HUD 日志

- (void)actShowHUDLog {
    char *raw = MFHUDLogRead();
    NSString *log = nil;
    if (raw != NULL) {
        log = [NSString stringWithUTF8String:raw];
        free(raw);
    }
    if (log.length == 0) log = @"（还没有 HUD 日志 —— 先点一次「启动悬浮窗」）";
    [self alert:@"HUD 日志" message:log];
}

#pragma mark - 小工具

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
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
    static NSString *cellID = @"MFRowCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cellID];
    }
    MFRow *row = self.sections[ip.section].rows[ip.row];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.detail;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = row.action.length ? UITableViewCellAccessoryDisclosureIndicator
                                           : UITableViewCellAccessoryNone;
    if (row.hasState) {
        cell.textLabel.textColor = row.ok ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
    }
    cell.selectionStyle = row.action.length ? UITableViewCellSelectionStyleDefault
                                            : UITableViewCellSelectionStyleNone;
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
