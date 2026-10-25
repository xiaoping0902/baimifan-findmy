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
#import "../Game/MFUEReader.h"
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

/* [M5.112] 自动挂载：不需要用户去列表里找进程 */
@property (nonatomic, strong) NSTimer *autoTimer;
@property (nonatomic, strong) UIBarButtonItem *kernelItem;   /* [M5.118] 标题随状态变 */
@property (nonatomic, assign) int  autoAttachedPid;   /* 已经连上的 pid，0=未连 */
@property (nonatomic, assign) int  autoTryPid;        /* 正在重试的 pid */
@property (nonatomic, assign) int  autoTryCount;      /* 该 pid 连续失败次数 */
@property (nonatomic, assign) BOOL autoBusy;          /* 正在连，别再进 */
@property (nonatomic, assign) NSInteger lastSignature; /* 列表指纹，用来判断要不要刷 UI */

- (BOOL)isGameCandidate:(MFProcessInfo *)p;
- (void)autoTick;
- (void)startAuto;
- (void)stopAuto;
- (void)attachToProcess:(MFProcessInfo *)cand;
- (void)refreshKernelItem;

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
        self.kernelItem,
    ];
    self.navigationController.toolbarHidden = NO;
    [self refreshKernelItem];

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

            /*
             * [M5.110] 把整张进程表落盘。
             *
             * 起因：用户报"列表里没有绿色高亮的那一行"，但远在电脑这端看不到
             * 列表长什么样，也没法区分「游戏被系统杀了」和「高亮判据不匹配」。
             * 现在每次枚举都写一份，AFC 直接拉，一眼就知道是哪一种。
             */
            {
                NSString *dir = @"/var/mobile/Media/mf-debug";
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:NULL];
                NSMutableString *dump = [NSMutableString string];
                [dump appendFormat:@"# procs=%lu enumRoute=%d\n",
                 (unsigned long)list.count, (int)route];
                for (MFProcessInfo *p in list) {
                    [dump appendFormat:@"%d\t%@\t%@\n", p.pid,
                     p.name ?: @"", p.path ?: @""];
                }
                [dump writeToFile:[dir stringByAppendingPathComponent:@"proclist.txt"]
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:NULL];
            }

            MFProcessInfo *cand = nil;
            for (MFProcessInfo *p in list) {
                if ([self isGameCandidate:p]) {
                    cand = p;
                    break;
                }
            }

            NSString *routeName = route == MFEnumRoutePrivileged ? @"路A host_priv"
                               : (route == MFEnumRouteDefault ? @"路B 免特权" : @"未知");
            NSString *base = list.count
                ? [NSString stringWithFormat:@"✓ %lu 个进程 · 枚举路由：%@\n内核：%@",
                   (unsigned long)list.count, routeName, k.statusText]
                : [NSString stringWithFormat:@"× 枚举失败（%@）\n内核：%@",
                   err ?: @"未知", k.statusText];
            self.headerLabel.text = cand
                ? [base stringByAppendingFormat:@"\n目标候选：%@ (pid %d)", cand.name, cand.pid]
                : [base stringByAppendingString:@"\n（列表里没有 dfm/tmgp 类进程）"];
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

#pragma mark - 自动挂载（M5.112）

/*
 * 用户不需要在列表里找进程。
 *
 * 每 2 秒用 sysctl 看一眼游戏还在不在（不碰内核，零风险）：
 *   · 没找到   → 头部显示「等待游戏启动」，同时把 autoAttachedPid 清零，
 *                等用户下次开游戏时重新连
 *   · 找到新的 → 自动跑一次跨进程自检（它自己 kopen/kclose），成功后把 pid
 *                写进 NSUserDefaults，后续绘制层直接用
 *   · 同一个   → 什么都不做，避免反复 kopen 把 PUAF 页搞脏
 *
 * 列表本身保留，但只当调试/兜底入口。
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshKernelItem];
    [self startAuto];
}

/*
 * ★ [M5.118] 底部那个按钮的标题必须跟着内核状态走。
 *
 * 用户报的问题："内核已经启动成功了，右下角还写着启动内核"。
 * 之前只有行为是切换的，标题是写死的 —— 点了之后看起来像没生效。
 */
- (UIBarButtonItem *)kernelItem {
    if (!_kernelItem) {
        _kernelItem = [[UIBarButtonItem alloc] initWithTitle:@"启动内核"
                                                       style:UIBarButtonItemStyleDone
                                                      target:self
                                                      action:@selector(startKernel)];
    }
    return _kernelItem;
}

- (void)refreshKernelItem {
    BOOL open = [MFKernel shared].isOpen;
    self.kernelItem.title = open ? @"关闭内核" : @"启动内核";
    self.kernelItem.style = open ? UIBarButtonItemStylePlain : UIBarButtonItemStyleDone;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopAuto];
}

- (void)startAuto {
    [self stopAuto];
    /* 立刻给一行可见的状态，别让用户以为页面没反应 */
    if (self.autoAttachedPid == 0) {
        self.headerLabel.text = @"正在检测进程…（每 2 秒自动扫描）";
    }
    self.autoTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(autoTick)
                                                   userInfo:nil
                                                    repeats:YES];
    [self autoTick];
}

- (void)stopAuto {
    if (self.autoTimer) {
        [self.autoTimer invalidate];
        self.autoTimer = nil;
    }
}

- (void)autoTick {
    if (self.autoBusy) {
        return;
    }
    /*
     * ★ [M5.119] 没点内核就什么都不做。
     *
     * 用户的原话：「没有启动内核不就会找？只能内核启动了才会找这个进程」。
     * 完全正确 —— 之前是自动 kopen，导致"没点内核它也在动"，失败还会
     * 反复开内核、养脏 PUAF 页。现在把内核当成硬前置：没有会话连扫都不扫。
     */
    if (![MFKernel shared].isOpen) {
        self.autoAttachedPid = 0;
        [[MFReadBackend shared] detachKFD];
        self.headerLabel.text = @"内核未启动 —— 先点右下角「启动内核」";
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MFKernel *k = [MFKernel shared];
        NSString *err = nil;
        NSArray<MFProcessInfo *> *list =
            [k enumerateProcessesWithRoute:MFEnumRouteNone error:&err];

        MFProcessInfo *cand = nil;
        for (MFProcessInfo *p in list) {
            if ([self isGameCandidate:p]) {
                cand = p;
                break;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshKernelItem];   /* 自动连接会自己开/关内核，标题跟着走 */
            /* 列表变了才刷 UI，避免每 2 秒跳一次 */
            NSInteger sig = (NSInteger)list.count * 1000003;
            for (MFProcessInfo *p in list) {
                sig = (sig * 31 + p.pid) % 1000000007;
            }
            if (sig != self.lastSignature) {
                self.lastSignature = sig;
                [self.all removeAllObjects];
                [self.all addObjectsFromArray:list];
                [self applyFilter];
            }

            if (cand == nil) {
                self.autoAttachedPid = 0;      /* 游戏没了：等他再开 */
                [[MFReadBackend shared] detachKFD];
                self.headerLabel.text = [NSString stringWithFormat:
                    @"等待游戏启动…（%lu 个进程，每 2 秒自动检测）",
                    (unsigned long)list.count];
                return;
            }

            if (cand.pid != self.autoTryPid) {
                self.autoTryPid = cand.pid;
                self.autoTryCount = 0;
            }

            if (cand.pid == self.autoAttachedPid) {
                return;                        /* 已连上，不重复开内核 */
            }

            /*
             * physpuppet 是概率性的，失败一次很常见。这里让它每 2 秒自动重试，
             * 连续 5 次才认输（再多就是 PUAF 页脏了，重试也没用，要杀 App）。
             */
            if (self.autoTryCount >= 5) {
                self.headerLabel.text = [NSString stringWithFormat:
                    @"%@ (pid %d) 连续 %d 次连接失败\n上滑杀掉 App 重开（清脏页）后再进本页",
                    cand.name, cand.pid, self.autoTryCount];
                return;
            }

            [self attachToProcess:cand];
        });
    });
}

- (void)attachToProcess:(MFProcessInfo *)cand {
    self.autoBusy = YES;
    const int pid = cand.pid;
    NSString *name = cand.name ?: @"game";
    self.headerLabel.text = [NSString stringWithFormat:
        @"发现 %@ (pid %d)，正在连接…", name, pid];
    [self.spinner startAnimating];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = MFCrossProcRun(pid);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.autoBusy = NO;
            [self refreshKernelItem];

            BOOL ok = [report containsString:@"RESULT OK"];
            if (ok) {
                self.autoAttachedPid = pid;
                self.autoTryCount = 0;
                [[NSUserDefaults standardUserDefaults] setInteger:pid forKey:@"mf.target.pid"];
                [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"mf.target.name"];
                [[NSUserDefaults standardUserDefaults] synchronize];

                /*
                 * ★ [M5.117] 把读取后端切到 KFD；[M5.119] 同时把模块基址交给
                 * UE4 读取层 —— 这之后「模块定位 / UE4 链解析」不用再靠 task port。
                 */
                if (![[MFReadBackend shared] attachKFDPid:pid]) {
                    NSLog(@"[MF][Read] attachKFDPid(%d) 失败，读取后端仍不可用", pid);
                }
                uint64_t modBase = MFCrossProcLastModuleBase();
                if (modBase != 0) {
                    [MFUEReader shared].libBase = modBase;
                    NSLog(@"[MF][UE4] 模块基址 = 0x%llx（来自 KFD 扫描）",
                          (unsigned long long)modBase);
                }
            } else {
                /*
                 * ★ [M5.116] 失败就锁住，不再自动重试。
                 *
                 * 真机证据：kopen 失败一次，perfmon 就已经锁住了；随后每一次
                 * 自动重试都在养 PUAF 脏页，最后以
                 *   pmap_mark_page_as_ppl_page_internal: page still has mappings
                 * 整机 panic（14:07:22 / 14:07:59）。一次机会，失败就等人。
                 */
                self.autoAttachedPid = pid;
                self.autoTryPid = pid;
                self.autoTryCount += 1;
            }

            self.headerLabel.text = [NSString stringWithFormat:
                @"%@ %@ (pid %d) · %@",
                ok ? @"已连接" : @"连接失败",
                name, pid,
                ok ? @"跨进程读已自证"
                   : @"上滑杀掉 App 重开后再试（不要连点）"];

            /* 只在第一次失败时弹窗 */
            if (!ok && self.autoTryCount == 1) {
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"连接失败（不会再自动重试）"
                                     message:report
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
        });
    });
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
     * ★ [M5.115] 同一个按钮兼作「关闭内核」。
     *
     * 主线是：用户点「启动内核」→ 内核保持开启 → 自动找进程 → 读内存。
     * 会话开着时按钮变成"关闭"，点一下正常释放（而不是让用户去强杀 App ——
     * 强杀带 KFD 的进程会让 perfmon 脏掉，只能重启设备）。
     */
    if ([MFKernel shared].isOpen) {
        [[MFKernel shared] stop];
        [self refreshKernelItem];
        self.autoAttachedPid = 0;
        self.autoTryCount = 0;
        [self reload];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"内核已关闭"
                             message:@"KFD 会话已正常释放（悬空页不再存在）。\n"
                                     @"现在可以安全地杀掉 App。\n\n"
                                     @"要重新读内存，再点一次「启动内核」。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

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

    /*
     * ★ [M5.119] 校准结束后保持会话。
     *
     * 语义按用户的要求定：点了「启动内核」→ 内核就在 → 页面自己去连进程。
     * 关会话的时机只有两个：用户点「关闭内核」，或 App 真的要退出。
     * （115 那版会 panic 是因为 App 在会话开着时崩溃；崩溃点已随 M5.116 修掉。）
     */
    MFCalibrateSetKeepKernel(YES);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mf-calibration.json"];
        NSString *report = MFCalibrateRun(path);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            [self reload];
            [self refreshKernelItem];   /* 校准会关会话，标题要变回「启动内核」 */

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
    } else if ([self isGameCandidate:p]) {
        c.accessoryType = UITableViewCellAccessoryNone;
        c.textLabel.textColor = [UIColor systemGreenColor];   // 防封目标游戏
    } else {
        c.accessoryType = UITableViewCellAccessoryNone;
        c.textLabel.textColor = [UIColor labelColor];
    }
    return c;
}

/*
 * [M5.110] 判定"这是不是那个游戏"。
 *
 * 原来的判据只看 path（containsString:@"dfm"），而 iOS 上 KERN_PROCARGS 常常
 * 拿不到完整路径（path 为空），于是绿色高亮永远不出现 —— 这不是"游戏没跑"，
 * 是判据本身漏了 name。名字（p_comm，16 字节）里就有 dfm，必须一起看。
 */
- (BOOL)isGameCandidate:(MFProcessInfo *)p {
    NSString *blob = [NSString stringWithFormat:@"%@ %@",
                      p.name ?: @"", p.path ?: @""].lowercaseString;
    if (blob.length == 0) return NO;
    if ([blob containsString:@"dfm"])     return YES;   // 三角洲 action: com.tencent.tmgp.dfm
    if ([blob containsString:@"tmgp"])    return YES;
    if ([blob containsString:@"delta"])   return YES;
    if ([blob containsString:@"shadow"])  return YES;   // 和平精英/暗区类
    if ([blob containsString:@"pubgm"])   return YES;
    if ([blob containsString:@"三角洲"])   return YES;
    return NO;
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
         * ★ [M5.108/109] task_for_pid 对 App Store 正版（自带反作弊的）游戏必然
         *   回 kr=0x5 —— 这条路是 PPL 封死的，不是 entitlement 的问题。
         *   这里改成走 KFD 的页表直读，并用「它的 Mach-O 头 == 0xfeedfacf」自证。
         *
         *   不要用 [MFKernel shared].isOpen 当门：校准结束时会 mf_kclose()，
         *   那个属性就是 mf_is_open()，此时必然为 NO。MFCrossProcRun 自己负责
         *   kopen/kclose，所以直接交给它。
         */
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
