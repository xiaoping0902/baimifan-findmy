//
//  MFProcessViewController.mm — 进程列表
//
//  M3 验收：能列出全系统进程 = 内核权限到手
//
#import "MFProcessViewController.h"
#import "../Kernel/MFKernel.h"
#import "../Kernel/MFCalibrate.h"
#import "../Kernel/MFCrossProc.h"
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
     * ⛔️ [M5.19] 加一道确认闸门 —— 因为这个按钮会让【整台 iPad 内核 panic 重启】。
     *
     * 真机证据（设备 /Panics 目录，2026-10-15 一晚）：
     *     panic-full-2026-10-15-214255.000.ips   ← 21:42:55
     *     panic-full-2026-10-15-223149.0002.ips  ← 22:31:49
     *     panic-full-2026-10-15-224435.000.ips   ← 22:44:35
     *     panic-full-2026-10-15-225826.000.ips   ← 22:58:26
     * 每个 panic 都配一个 ResetCounter（重启计数器）—— 四次都是整机重启。
     *
     * 内核 panic 内容（四次一致）：
     *     pmap_map_cpu_windows_copy_internal:
     *         attempted to map a managed page @pmap.c:10917
     * 这是 vm_copy 碰到 KFD 制造的悬空页时的典型后果。
     *
     * 而且 panic 重启比正常重启慢很多（要落 panic 日志 + iOS 走额外诊断），
     * 连崩四次就是用户感觉的「重启要很久很久」。
     *
     * ⚠ 范围说明：上面这四次 panic 是 **2026-10-15、旧设备 iPad8,11 / 16.6.1**
     *   的历史记录（见 docs 与 /Panics 里的 panic-full-*.ips）。
     *   本机 iPad14,4 / 16.1 的 /Panics 目录目前是**空的** —— 还没因 KFD panic 过。
     *   但这只是"还没发生"，不代表不会发生；panic 原理对这台同样适用。
     *
     * ★ [M5.87] 这里原来写着「好消息：主线根本不需要内核」。
     *   那个结论**已被真机推翻**：读链的门条件确实只看 task port，
     *   可 task port 恰恰拿不到 ——
     *       task_for_pid(游戏/launchd/SpringBoard) 全 kr=0x5（PPL 按 CS_HARD 拒）
     *       processor_set_tasks 全 kr=0x4
     *   所以"task port 来自 task_for_pid + entitlement"这条前提不成立。
     *   没有内核读写 ⇒ 没有 task port ⇒ 读不了游戏内存 ⇒ 没有绘制。
     *   内核不是可选项，是唯一路径。
     */
    /*
     * ★ [M5.87] 这段文案原来在劝退用户（默认按钮是"取消（推荐）"），
     * 依据是"主线不需要内核，一键开始走 task_for_pid 就够"。
     * 那个前提已被真机推翻：task_for_pid 在 A12+/iOS15+ 被 PPL 全线封死
     * （实测游戏 / launchd / SpringBoard 全 kr=0x5，processor_set 全 kr=0x4）。
     *
     * 也就是说：内核从"可选的风险优化"变成了"唯一可走的路径"。
     * 文案必须如实反映这一点 —— 既要保留 panic 风险提示（那是真的），
     * 又不能让用户以为"不点内核也行"（那是假的）。
     */
    NSInteger panics = [[NSUserDefaults standardUserDefaults] integerForKey:@"mf.kernel.panicWarned"];
    UIAlertController *warn = [UIAlertController
        alertControllerWithTitle:@"⚠️ 内核是当前唯一路径"
                         message:[NSString stringWithFormat:
                                 @"先说风险（真的）：\n"
                                 @"  设备日志里已经有【4 次内核 panic】：\n"
                                 @"    21:42:55 · 22:31:49 · 22:44:35 · 22:58:26\n"
                                 @"  每次 panic = 一次整机重启，而且比正常重启慢很多。\n\n"
                                 @"再说为什么还得点：\n"
                                 @"  task_for_pid 已被内核 PPL 封死 —— 实测\n"
                                 @"    游戏/launchd/SpringBoard 全部 kr=0x5\n"
                                 @"    processor_set_tasks 全部 kr=0x4\n"
                                 @"  所以「★ 一键开始」拿不到 task port，数据链起不来。\n"
                                 @"  没有内核读写，就没有任何办法读游戏内存。\n\n"
                                 @"本版本（M5.87）起，拿到内核后会先用 proc patch\n"
                                 @"绕开 taskgated 的 CS_HARD 拒绝，再重试 task_for_pid。\n\n"
                                 @"确定要启动内核吗？%@",
                                 panics > 0 ? @"\n（你已经走过一次了）" : @""]
                  preferredStyle:UIAlertControllerStyleAlert];
    [warn addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [warn addAction:[UIAlertAction actionWithTitle:@"仍要启动内核"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *_) {
        [[NSUserDefaults standardUserDefaults] setInteger:panics + 1
                                                   forKey:@"mf.kernel.panicWarned"];
        [self reallyStartKernel];
    }]];
    [self presentViewController:warn animated:YES completion:nil];
}

- (void)reallyStartKernel {
    /*
     * ★ [M5.14] 一点就走 —— 不再弹选择框。
     *
     * 用户的原话：「为什么要我选择呢 不能直接我点击启动就直接自己选择启动呀」
     *
     * 参数全部自动决定，依据是三个独立来源的交集：
     *
     *   PUAF 方法 = landa
     *       白米饭自己的版本判定表（三重复核）：
     *         physpuppet 修复于 iOS 16.4
     *         smith      修复于 iOS 16.5.1
     *         landa      修复于 iOS 17.0
     *       → 16.6.1 上只剩 landa 可用。
     *
     *   PUAF 页数 = 按 hw.memsize 查 Dopamine 的表
     *       Dopamine 对 ≥5GB 设备原话：
     *         "These devices are remarkably more reliable with 3072"
     *       → 6GB 设备用 3072。
     *
     *   kread/kwrite = sem_open / sem_open
     *       16.3+ 上 kqueue_workloop_ctl 已废（krkw.h 有 assert 拦截）。
     *
     * 想手动改参数的话在「环境检测」下面的调试入口里，普通流程不需要。
     */
    /*
     * ★ [M5.95 · 2026-10-24] 参数改了：landa/3072 → physpuppet/1024
     *
     * 真机实测（iPad14,4 / iPadOS 16.1 / Darwin 22.1.0 / T8112）：
     *     landa + 3072 + sem_open  → kopen 卡在内部循环，12 分钟不返回
     *     physpuppet + 1024 + sem_open → 235~261 ms 成功，连续三次
     *
     * 另外 libkfd.h 里的重试只对 landa 生效：
     *     if (fail && (puaf_method == puaf_landa)) { …重试… }
     * physpuppet 失败不重试，所以调用侧要允许用户再点一次。
     *
     * physpuppet 对应 CVE-2023-23536，iOS 16.4 才修复 → 16.1 在范围内。
     * kread/kwrite 仍必须是 sem_open（16.3+ kqueue 被 krkw.h assert 拦）。
     */
    NSInteger pm = 0;                                        // 0 = physpuppet
    uint64_t pages = 1024;                                   // physpuppet 不需要 3072
    [[NSUserDefaults standardUserDefaults] setInteger:pm forKey:@"mf.kfd.puafMethod"];
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)pages forKey:@"mf.kfd.puafPages"];

    [self reallyStartKernelWithPages:pages];
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
            /*
             * ★ [M5.95] 启动成功后【立即自动校准】。
             *
             * 校准内容：反推 proc->task / vm_map->pmap / pmap 根页表字段，
             * 并用「读自己 Mach-O 头 == 0xfeedfacf」做自验证。
             * 结果写 mf-calibration.json，同时弹窗显示。
             *
             * 为什么放在 App 里而不是外部脚本：只有这里能直接拿到 g_kfd，
             * 外部去扫内存找句柄曾把用户地址当成内核地址 → copy_validate panic。
             *
             * 注意 MFCalibrateRun 结束时会 mf_kclose()：校准是一次性诊断，
             * 关掉才不会留下悬空页（悬空页不释放，进程退出就是 panic）。
             */
            [self runCalibrationAfterKernel:message];
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

/// 内核起来后自动跑一次偏移校准（proc->task / vm_map->pmap / pmap 根页表）
- (void)runCalibrationAfterKernel:(NSString *)kernelMessage {
    self.headerLabel.text = @"内核已起，正在校准偏移…";
    [self.spinner startAnimating];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mf-calibration.json"];
        NSString *report = MFCalibrateRun(path);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            [self reload];

            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"校准结果"
                                 message:[NSString stringWithFormat:@"%@\n\n%@",
                                          kernelMessage, report]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"复制全文"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
                [UIPasteboard generalPasteboard].string = report;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
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
        /*
         * ★ [M5.108] task_for_pid 对 App Store 正版（自带反作弊的）游戏必然
         *   回 kr=0x5 —— 这条路是 PPL 封死的，不是 entitlement 的问题。
         *   现在改成：内核已打开时，直接走 KFD 的页表直读去读这个进程，
         *   并用「它的 Mach-O 头 == 0xfeedfacf」自证读通了。
         */
        if ([MFKernel shared].isOpen) {
            [[NSUserDefaults standardUserDefaults] setInteger:p.pid forKey:@"mf.target.pid"];
            [[NSUserDefaults standardUserDefaults] setObject:p.name forKey:@"mf.target.name"];
            [[NSUserDefaults standardUserDefaults] synchronize];

            /*
             * 只弹一个框：先弹「正在验证」再弹「结果」会撞 present，第二个框
             * 被 UIKit 丢掉，报告就只能从 mf-debug 文件里看。这里后台算完
             * 一次性显示（同时落盘 /mf-debug/mf-crossproc.txt）。
             */
            self.headerLabel.text = [NSString stringWithFormat:
                                     @"task port 不可用，正在用 KFD 读 %@ (pid %d)…",
                                     p.name, p.pid];
            [self.spinner startAnimating];

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *report = MFCrossProcRun(p.pid);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.spinner stopAnimating];
                    [self reload];
                    UIAlertController *a = [UIAlertController
                        alertControllerWithTitle:@"跨进程直读自检"
                                         message:report
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];
                    [self presentViewController:a animated:YES completion:nil];
                });
            });
            return;
        }

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
