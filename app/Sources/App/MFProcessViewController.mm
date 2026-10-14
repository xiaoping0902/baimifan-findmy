//
//  MFProcessViewController.mm — 进程列表
//
//  M3 验收：能列出全系统进程 = 内核权限到手
//
#import "MFProcessViewController.h"
#import "../Kernel/MFKernel.h"
#import "../Game/MFGameReader.h"
#import "../Read/MFReadBackend.h"
#import "../Game/Offsets.h"

@interface MFProcessViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableArray<MFProcessInfo *> *all;
@property (nonatomic, strong) NSMutableArray<MFProcessInfo *> *shown;
@property (nonatomic, copy) NSString *filter;

@end

@implementation MFProcessViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"进程列表";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.all = [NSMutableArray array];
    self.shown = [NSMutableArray array];
    self.filter = @"";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];

    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"能力探测" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(probe)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:@"启动内核" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(startKernel)],
    ];
    self.navigationController.toolbarHidden = NO;

    // 顶部：搜索 + 状态
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 96)];
    header.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, header.bounds.size.width, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder = @"筛选进程名";
    self.searchBar.delegate = self;
    [header addSubview:self.searchBar];

    self.headerLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, header.bounds.size.width - 60, 40)];
    self.headerLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.headerLabel.numberOfLines = 2;
    self.headerLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.headerLabel.textColor = [UIColor secondaryLabelColor];
    [header addSubview:self.headerLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(header.bounds.size.width - 36, 68);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [header addSubview:self.spinner];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = header;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self reload];
}

- (void)reload {
    self.headerLabel.text = @"正在枚举…";
    [self.spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MFKernel *k = [MFKernel shared];
        NSString *err = nil;
        MFEnumRoute route = [k detectRoute];
        NSArray<MFProcessInfo *> *list = [k enumerateProcessesWithRoute:MFEnumRouteNone error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            [self.all removeAllObjects];
            [self.all addObjectsFromArray:list];
            [self applyFilter];
            NSString *routeName = route == MFEnumRoutePrivileged ? @"路A host_priv"
                               : (route == MFEnumRouteDefault ? @"路B 免特权" : @"未知");
            self.headerLabel.text = list.count
                ? [NSString stringWithFormat:@"✓ %lu 个进程 · 枚举路由：%@\n内核：%@",
                   (unsigned long)list.count, routeName, k.statusText]
                : [NSString stringWithFormat:@"× 枚举失败（%@）\n内核：%@",
                   err ?: @"未知", k.statusText];
        });
    });
}

- (void)applyFilter {
    [self.shown removeAllObjects];
    if (self.filter.length == 0) {
        [self.shown addObjectsFromArray:self.all];
    } else {
        for (MFProcessInfo *p in self.all) {
            if ([p.name localizedCaseInsensitiveContainsString:self.filter] ||
                [p.path localizedCaseInsensitiveContainsString:self.filter]) {
                [self.shown addObject:p];
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark - 动作

- (void)probe {
    self.headerLabel.text = @"能力探测中…";
    [self.spinner startAnimating];
    [[MFKernel shared] probeCapabilitiesWithCompletion:^(NSString *report) {
        [self.spinner stopAnimating];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"内核能力探测"
                                                                  message:report
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = report;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }];
}

- (void)startKernel {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"启动内核"
                         message:@"将执行 KFD 链：\n"
                                 @"kopen(2048, landa, kread_sem_open, kwrite_sem_open)\n\n"
                                 @"⚠️ 16.6.1 上唯一可用组合。"
                                 @"失败可能表现为卡顿或闪退，严重时设备重启。\n\n"
                                 @"确认继续？"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"启动" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *_) {
        self.headerLabel.text = @"内核启动中（可能要几十秒）…";
        [self.spinner startAnimating];
        [[MFKernel shared] startWithPuafPages:2048 completion:^(BOOL ok, NSString *message) {
            [self.spinner stopAnimating];
            [self alert:ok ? @"启动成功" : @"启动失败" message:message];
            [self reload];
        }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)alert:(NSString *)t message:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *_) { [self reload]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 搜索

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.filter = text;
    [self applyFilter];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.shown.count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.shown.count ? [NSString stringWithFormat:@"%lu 个", (unsigned long)self.shown.count] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"proc";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:rid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        c.detailTextLabel.numberOfLines = 2;
    }
    MFProcessInfo *p = self.shown[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%d  ·  %@", p.pid, p.name];
    c.textLabel.font = [UIFont systemFontOfSize:15];
    c.detailTextLabel.text = p.path;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    // 当前已绑定目标高亮
    if ([MFGameReader shared].targetTaskPort == p.taskPort && p.taskPort != 0) {
        c.accessoryType = UITableViewCellAccessoryCheckmark;
        c.textLabel.textColor = [UIColor systemBlueColor];
    } else if ([p.name hasPrefix:@"ShadowTracker"] || [p.path containsString:@"DeltaForce"] ||
        [p.path containsString:@"dfm"] || [p.path containsString:@"pubgm"]) {
        c.accessoryType = UITableViewCellAccessoryNone;
        c.textLabel.textColor = [UIColor systemGreenColor];   // 防封目标游戏
    } else {
        c.accessoryType = UITableViewCellAccessoryNone;
        c.textLabel.textColor = [UIColor labelColor];
    }
    return c;
}

/// 点进程 = 绑定为读取目标（写 task port 到读取后端 → 开门条件）
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MFProcessInfo *p = self.shown[ip.row];
    if (p.taskPort == 0) {
        [self alert:@"无法绑定" message:@"该进程没有有效的 task port"];
        return;
    }

    MFGameReader *r = [MFGameReader shared];
    r.targetTaskPort = p.taskPort;
    [MFReadBackend shared].modeFlag = YES;

    // 顺便把进程名写回当前档案，方便后续自动匹配
    MFGameProfile *prof = [MFOffsets shared].current;
    if (prof.processName.length == 0) {
        prof.processName = p.name;
        [[MFOffsets shared] saveCalibration];
    }

    [tv reloadData];

    NSString *msg = [NSString stringWithFormat:
        @"已绑定：%@ (pid %d)\ntask port = 0x%x\n\n"
        @"门条件：%@\n\n"
        @"下一步：回到悬浮窗看绘制层，或在这里往下拉刷新后\n"
        @"在「启动内核」页点「能力探测」看读取统计。",
        p.name, p.pid, p.taskPort,
        [MFReadBackend shared].gateOpen ? @"✓ 已就绪" : @"× 未就绪"];
    [self alert:@"绑定成功" message:msg];
}

@end
