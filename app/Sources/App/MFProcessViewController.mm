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
#import <mach/mach.h>
#import <sys/sysctl.h>       // sysctlbyname（读 hw.memsize）          // mach_task_self / mach_port_deallocate

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
        [[UIBarButtonItem alloc] initWithTitle:@"内核日志" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(showKernelLog)],
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
    /*
     * ★ PUAF 页数可调（[M5.9]）
     *
     * 为什么做成可调：真机日志里 kopen 失败在
     *     assertion failed: (landa retry limit reached)
     * 而 krkw_run 只有一处能返回 -1 —— krkw_helper_grab_free_pages：
     *
     *     goal = number_of_puaf_pages / 4;          // 2048 → 512
     *     数「2048 个 PUAF 悬空页里还剩多少个没被系统回收」，
     *     凑不够 512 就 print_warning("failed to grab free pages goal") 并返回 -1。
     *
     * 也就是说：这是【内存压力】问题，而且【目标 = 页数/4，页数越小越容易达成】。
     * 所以把页数做成可选，失败时用户可以降档重试。
     */
    NSInteger pages = [[NSUserDefaults standardUserDefaults] integerForKey:@"mf.kfd.puafPages"];
    if (pages < 16) pages = (NSInteger)[MFKernel recommendedPuafPages];   // ★ 自动（Dopamine 的表）
    NSInteger pm = [[NSUserDefaults standardUserDefaults] integerForKey:@"mf.kfd.puafMethod"];
    if (pm < 0 || pm > 2) pm = 2;      // 默认 landa （16.6.1 上唯一可用，见分析报告）

    uint64_t mem = 0; size_t ms = sizeof(mem);
    sysctlbyname("hw.memsize", &mem, &ms, NULL, 0);
    size_t avail = [MFKernel availableMemory];

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"启动内核"
                         message:[NSString stringWithFormat:
                                 @"RAM %.1f GB · 可用内存 %.0f MB\n"
                                 @"本次：%ld 页 · %@\n"
                                 @"目标悬空页门槛 = %ld/4 = %ld\n\n"
                                 @"★ 页数按 Dopamine 的表自动选（6GB+ → 3072，\n"
                                 @"  原话「remarkably more reliable with 3072」）\n\n"
                                 @"⚠️ 16.6.1 上只有 landa 可用：\n"
                                 @"   physpuppet 修复于 16.4 · smith 修复于 16.5.1\n\n"
                                 @"失败后本次运行会禁止再试。",
                                 mem / 1073741824.0, avail / 1048576.0,
                                 (long)pages,
                                 pm == 2 ? @"landa" : (pm == 1 ? @"smith" : @"physpuppet"),
                                 (long)pages, (long)(pages / 4)]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    /*
     * ⚠️ 枚举值必须与 libkfd.h 一致：
     *     enum puaf_method { puaf_physpuppet = 0, puaf_smith = 1, puaf_landa = 2 };
     * ⚠️ 16.6.1 上 landa 是【唯一】可用的（physpuppet 修复于 16.4，smith 修复于 16.5.1）
     */
    NSArray *tiers = @[
        @[@"landa · 3072（★ Dopamine 推荐）", @2, @3072, @"6GB 设备首选"],
        @[@"landa · 2048（我们一直用的）",     @2, @2048, @"之前失败的配置"],
        @[@"landa · 4096（更激进）",           @2, @4096, @"若 3072 仍不行可试"],
        @[@"landa · 1024",                     @2, @1024, @"小页数对照"],
        @[@"smith · 1024（应无效）",           @1, @1024, @"16.5.1 已修复"],
        @[@"physpuppet · 2048（应无效）",      @0, @2048, @"16.4 已修复"],
    ];
    for (NSArray *t in tiers) {
        NSString *title = [NSString stringWithFormat:@"%@ — %@", t[0], t[3]];
        [a addAction:[UIAlertAction actionWithTitle:title
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            [[NSUserDefaults standardUserDefaults] setInteger:[t[1] integerValue] forKey:@"mf.kfd.puafMethod"];
            [self reallyStartKernelWithPages:(uint64_t)[t[2] unsignedIntegerValue]];
        }]];
    }
    [self presentViewController:a animated:YES completion:nil];
}

- (void)reallyStartKernelWithPages:(uint64_t)pages {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)pages forKey:@"mf.kfd.puafPages"];
    self.headerLabel.text = [NSString stringWithFormat:@"内核启动中（%llu 页，可能要几十秒）…",
                             (unsigned long long)pages];
    [self.spinner startAnimating];

    [[MFKernel shared] startWithPuafPages:pages completion:^(BOOL ok, NSString *message) {
        [self.spinner stopAnimating];
        [self reload];

        if (ok) {
            [self alert:@"启动成功" message:message];
            return;
        }

        // ★ 失败后强制重启：fd 表已污染 + 内核态可能有残留 PUAF 页
        UIAlertController *f = [UIAlertController
            alertControllerWithTitle:@"启动失败"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [f addAction:[UIAlertAction actionWithTitle:@"看内核日志"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            [self showKernelLog];
        }]];
        [f addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *_) {
            [MFKernel forceRestartWithReason:@"内核启动失败"];
        }]];
        [self presentViewController:f animated:YES completion:nil];
    }];
}

/// 内核日志查看器：kfd 用 printf 输出的 9 个偏移查找过程
- (void)showKernelLog {
    NSString *log = [MFKernel kernelLog];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"内核日志"
                         message:[NSString stringWithFormat:
                                  @"%@\n\n"
                                  @"关注这几行：\n"
                                  @"  defeated kaslr, kbase: …    ← 破 KASLR 成功\n"
                                  @"  pfinder_init: success!       ← patchfinder 初始化\n"
                                  @"  cdevsw / gPhysBase / …       ← 9 个偏移逐个回填\n"
                                  @"哪一行缺了，就死在那一步。",
                                  log]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"复制全文" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *_) {
        [UIPasteboard generalPasteboard].string = log;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
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

/// 点进程 = 绑定为读取目标（按需取 task port → 写进读取后端 → 开门条件）
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MFProcessInfo *p = self.shown[ip.row];

    /*
     * ★ 审查修正（P1-2）：枚举阶段不再预取端口（那会泄漏 N 个端口右）。
     *   真正要读哪个进程，在这里为它单独取一次。
     */
    NSError *err = nil;
    uint32_t port = [MFKernel acquireTaskPortForPid:p.pid error:(NSString **)&err];
    if (port == MACH_PORT_NULL) {
        [self alert:@"无法绑定"
             message:[NSString stringWithFormat:
                      @"为 %@ (pid %d) 取 task port 失败。\n\n%@\n\n"
                      @"先确认：「启动内核」页的能力探测里 "
                      @"task_for_pid(self) 那一行是不是成功。",
                      p.name, p.pid, err.localizedDescription ?: @"(无错误信息)"]];
        return;
    }

    MFGameReader *r = [MFGameReader shared];

    // 换目标前先把上一个端口还回去，避免累积
    if (r.targetTaskPort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), r.targetTaskPort);
    }

    r.targetTaskPort = port;
    [MFReadBackend shared].modeFlag = YES;

    /*
     * ★ 审查修正（P0-2）：绘制跑在【另一个进程】里（posix_spawn 出来的 HUD）。
     *   端口名字只在创建它的 IPC space 有效，所以主进程拿到的端口
     *   HUD 进程用不了。这里把目标 pid 记下来，
     *   HUD 进程启动/读取时用同一个方法为它自己取一份端口。
     */
    [[NSUserDefaults standardUserDefaults] setInteger:p.pid forKey:@"mf.target.pid"];
    [[NSUserDefaults standardUserDefaults] setObject:p.name forKey:@"mf.target.name"];
    [[NSUserDefaults standardUserDefaults] synchronize];

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
        @"⚠️ 绘制跑在独立的 HUD 进程里，它拿不到这个端口号。\n"
        @"已把目标 pid=%d 落盘，HUD 启动时会自己再取一份。\n\n"
        @"下一步：启动悬浮窗，看绘制层是否出画面。",
        p.name, p.pid, port,
        [MFReadBackend shared].gateOpen ? @"✓ 已就绪" : @"× 未就绪",
        p.pid];
    [self alert:@"绑定成功" message:msg];
}

@end
