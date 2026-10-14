//
//  MFAntiBan.h — 防封
//
//  实现依据：《清理Key与防封_实现细节.md》§3
//    原实现：
//      +[dfyyDG Reuid: <bundleID> idv: <统一值> ida: <统一值>]   ← 四个腾讯游戏逐个处理
//      +[dfyyDG Resetsj: <bundleID>]                            ← 每个调两次
//      +[dfyyDG2 lrproki: "lsd"]                                ← 收尾
//      以及 sub_100990D30 的 plist 重写链：
//        contentsAtPath: → propertyListWithData: → mutableCopy →
//        removeAllObjects / objectForKeyedSubscript: / hasPrefix: →
//        dataWithPropertyList: → writeToFile:atomically:
//    目标文件：/var/containers/Shared/SystemGroup/<UUID>/Library/.../com.apple.lsdidentifiers.plist
//    涉及键：LSAdvertiserIdentifier / LSVendorIdentifier / LSVendors / LSApplications
//
//  ★ 分析结论：idv/ida 不是现取的 identifierForVendor/advertisingIdentifier，
//    而是【同一个运行时生成的统一值】。本实现按此语义：每个目标一个 UUID，
//    同时写入 idv 与 ida 两个键。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MFAntiBan : NSObject

+ (instancetype)shared;

#pragma mark - 探测

/// 定位 lsdidentifiers.plist
- (nullable NSString *)plistPath;

/// 只读：转储当前 plist 的顶层结构（键 → 类型/条目数），供真机校准用
- (NSDictionary *)dumpStructure;

/// 只读：某个 bundleID 当前的标识符记录
- (nullable NSDictionary *)currentIdentifiersForBundleID:(NSString *)bundleID;

#pragma mark - 执行

/// 为四个游戏重置标识符（生成新 UUID 并写回 plist）
- (NSDictionary<NSString *, NSString *> *)resetIdentifiersForGamesWithError:(NSString **)err;

/// 底层：为指定 bundleID 列表重置
- (NSDictionary<NSString *, NSString *> *)resetIdentifiersForBundleIDs:(NSArray<NSString *> *)bundleIDs
                                                                 error:(NSString **)err;

/// 尝试让 lsd 重新读取（原实现收尾动作 lrproki:("lsd")）
- (BOOL)restartLSD;

/// 备份当前 plist 到 Documents（改动前保险）
- (nullable NSString *)backupPlistWithError:(NSString **)err;

@end

NS_ASSUME_NONNULL_END
