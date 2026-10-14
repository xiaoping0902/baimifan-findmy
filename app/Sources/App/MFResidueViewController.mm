//
//  MFResidueViewController.mm — 清理系统残留
//
//  流程（对齐白米饭「先出清单再动手」的安全口径）：
//    进入 → 后台扫描 → 列出全部【将被删除】的条目（默认全选）
//         → 可逐项取消勾选 → 「删除选中项」→ 二次确认 → 执行 → 结果
//
#import "MFResidueViewController.h"
#import "../Features/MFCleanup.h"

@interface MFResidueViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<MFCleanupItem *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedPaths;
@property (nonatomic, strong) MFCleanupResult *scanStats;
@property (nonatomic, assign) BOOL scanning;

@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@end

@implementation MFResidueViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"清理系统残留";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.items = [NSMutableArray array];
    self.selectedPaths = [NSMutableSet set];

    // ── 顶部摘要 + 操作条 ──
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 96)];
    header.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    self.summaryLabel = [[UILabel alloc] initWithFrame:CGRectInset(header.bounds, 16, 12)];
    self.summaryLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.summaryLabel.numberOfLines = 4;
    self.summaryLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.summaryLabel.textColor = [UIColor secondaryLabelColor];
    self.summaryLabel.text = @"正在扫描…";
    [header addSubview:self.summaryLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(header.bounds.size.width - 40, 40);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [header addSubview:self.spinner];

    // ── 表格 ──
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

    // ── 底部工具栏 ──
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全不选" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(selectNone)];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"重新扫描" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(rescan)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:@"删除选中项" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(confirmDelete)],
    ];
    self.navigationController.toolbarHidden = NO;

    [self rescan];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

#pragma mark - 扫描

- (void)rescan {
    if (self.scanning) return;
    self.scanning = YES;
    [self.spinner startAnimating];
    self.summaryLabel.text = @"正在扫描…";
    [self.items removeAllObjects];
    [self.selectedPaths removeAllObjects];
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MFCleanupResult *stats = nil;
        NSArray<MFCleanupItem *> *found = [[MFCleanup shared] scanWithStats:&stats];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            [self.spinner stopAnimating];
            self.scanStats = stats;
            [self.items addObjectsFromArray:found];
            for (MFCleanupItem *it in found) [self.selectedPaths addObject:it.path];
            [self updateSummary];
            [self.tableView reloadData];
            if (found.count == 0) {
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"没有可清理项"
                                     message:@"扫描完成，未发现符合规则的残留条目。\n（若 /var 等目录不可读，请回到控制台检查 entitlements 自检）"
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
        });
    });
}

- (void)updateSummary {
    NSDictionary *rs = [MFCleanup ruleSummary];
    self.summaryLabel.text = [NSString stringWithFormat:
        @"规则：%@ 个目录 · 黑名单 %@ 条 · 白名单 %@ 条\n"
        @"扫描：%lu 个目录 / %lu 个条目\n"
        @"选中：%lu 项（将删除）\n"
        @"保护跳过：%lu 项",
        rs[@"dirs"], rs[@"blacklistRules"], rs[@"whitelistRules"],
        (unsigned long)self.scanStats.scannedDirs,
        (unsigned long)self.scanStats.scannedEntries,
        (unsigned long)self.selectedPaths.count,
        (unsigned long)self.scanStats.protectedSkipped];
}

#pragma mark - 选择

- (void)selectNone {
    [self.selectedPaths removeAllObjects];
    [self updateSummary];
    [self.tableView reloadData];
}

#pragma mark - 删除

- (void)confirmDelete {
    NSArray<MFCleanupItem *> *picked = [self pickedItems];
    if (picked.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没选任何项"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"确认删除 %lu 项？", (unsigned long)picked.count]
                         message:@"此操作会直接删除磁盘文件，且不可撤销。\n\n其中包含本应用之外的系统目录条目。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确认删除" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *_) { [self doDelete:picked]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSArray<MFCleanupItem *> *)pickedItems {
    NSMutableArray *out = [NSMutableArray array];
    for (MFCleanupItem *it in self.items) {
        if ([self.selectedPaths containsObject:it.path]) [out addObject:it];
    }
    return out;
}

- (void)doDelete:(NSArray<MFCleanupItem *> *)picked {
    self.summaryLabel.text = @"正在删除…";
    [self.spinner startAnimating];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MFCleanupResult *r = [[MFCleanup shared] deleteItems:picked];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            NSMutableString *msg = [NSMutableString string];
            [msg appendFormat:@"成功删除 %lu 项", (unsigned long)r.deleted.count];
            if (r.protectedSkipped) [msg appendFormat:@"\n保护跳过 %lu 项", (unsigned long)r.protectedSkipped];
            if (r.failed.count) {
                [msg appendFormat:@"\n\n失败 %lu 项：", (unsigned long)r.failed.count];
                for (NSString *f in [r.failed subarrayWithRange:NSMakeRange(0, MIN(5, r.failed.count))]) {
                    [msg appendFormat:@"\n· %@", f];
                }
            }
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清理完成"
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *_) { [self rescan]; }]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.items.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.items.count ? @"将被删除的条目（点按可取消勾选）" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"residue";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:rid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        c.detailTextLabel.numberOfLines = 2;
    }
    MFCleanupItem *it = self.items[ip.row];
    c.textLabel.text = it.name;
    c.textLabel.font = [UIFont systemFontOfSize:15];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
                              it.ruleRoot,
                              it.isDirectory ? @"目录" : [MFPaths humanSize:it.size],
                              [it.matchedBy isEqualToString:@"default"] ? @" · 默认规则" : @""];
    BOOL on = [self.selectedPaths containsObject:it.path];
    c.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.textLabel.textColor = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MFCleanupItem *it = self.items[ip.row];
    if ([self.selectedPaths containsObject:it.path]) {
        [self.selectedPaths removeObject:it.path];
    } else {
        [self.selectedPaths addObject:it.path];
    }
    [self updateSummary];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

@end
