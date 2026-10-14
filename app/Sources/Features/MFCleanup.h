//
//  MFCleanup.h — 清理系统残留
//
//  实现依据：《白米饭补充分析-启动窗口与功能.md》§5「清理系统残留」
//    · 内嵌 plist 配置（本工程用 Resources/cleanup_rules.plist），共 25 个目录键
//    · 枚举每个配置目录的【一级子项】，用子项名匹配规则
//    · 规则优先级：blacklist 命中→删；未命中再看 whitelist→保留；
//                  两者都未命中则仅当 default=="blacklist" 时删
//    · 删除前有一层保护名单：路径长度<9，或含 .pid / MGNH / .apple /
//      com.apple.dfkr / killapps / leemin  → 跳过
//
//  ★ 本实现默认【只扫描不删除】，调用 deleteItems: 才会真正落盘。
//
#import <Foundation/Foundation.h>
#import "MFPaths.h"

NS_ASSUME_NONNULL_BEGIN

@interface MFCleanupResult : NSObject
@property (nonatomic, assign) NSUInteger scannedDirs;
@property (nonatomic, assign) NSUInteger scannedEntries;
@property (nonatomic, assign) NSUInteger selected;
@property (nonatomic, assign) NSUInteger protectedSkipped;
@property (nonatomic, strong) NSMutableArray<MFCleanupItem *> *deleted;
@property (nonatomic, strong) NSMutableArray<NSString *> *failed;
@end

@interface MFCleanup : NSObject

+ (instancetype)shared;

/// 扫描（dry-run）：返回全部【将被删除】的条目，不做任何写操作
- (NSArray<MFCleanupItem *> *)scanWithStats:(MFCleanupResult *_Nullable *_Nullable)stats;

/// 执行删除。传入 scan 的结果，避免二次扫描导致清单漂移
- (MFCleanupResult *)deleteItems:(NSArray<MFCleanupItem *> *)items;

/// 规则统计（用于界面展示：25 个目录、多少条规则）
+ (NSDictionary *)ruleSummary;

@end

NS_ASSUME_NONNULL_END
