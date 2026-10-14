//
//  MFKeychain.h — keychain-2.db 那条线
//
//  实现依据：《清理Key与防封_实现细节.md》§1 + 《白米饭补充分析》§5
//    「高级游戏模式」和「清理 Key」操作的是【同一个文件】/var/Keychains/keychain-2.db
//        · 游戏模式 → 改这个库的【文件权限】
//        · 清理 Key → 改这个库的【内容】
//
//  清理 Key 的原实现（已证）：
//      sqlite3_open("/var/Keychains/keychain-2.db", &db);
//      sqlite3_exec(db, "DELETE FROM <表名> WHERE agrp like '%%<bundleID>%%'", ...);
//    表名遍历 iOS 钥匙串的四张表：genp / inet / cert / keys
//    条件字段是 agrp（access group）
//
//  高级游戏模式（已证到权限位，chmod 具体值未证 → 本实现做成可配置）：
//      读 stat.st_mode & 0x80（S_IWUSR，属主写位）
//        有该位 → 显示「已关闭」；无该位 → 显示「✅已开启」
//      stat 失败也按「已开启」显示
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MFKeychainResult : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *matchedPerTable;  // 表 → 命中数
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *deletedPerTable;  // 表 → 删除数
@property (nonatomic, assign) NSInteger totalMatched;
@property (nonatomic, assign) NSInteger totalDeleted;
@property (nonatomic, copy, nullable) NSString *error;
@end

@interface MFKeychain : NSObject

+ (instancetype)shared;

#pragma mark - 清理 Key

/// 防封针对的四个目标（分析已证：CFString 长度逐个核对吻合）
+ (NSArray<NSString *> *)gameBundleIDs;

/// 只统计不删除（dry-run）
- (MFKeychainResult *)countForBundleID:(NSString *)bundleID;

/// 真正执行 DELETE
- (MFKeychainResult *)deleteForBundleID:(NSString *)bundleID;

/// 对四个游戏全跑一遍（dry-run）
- (NSArray<MFKeychainResult *> *)countForAllGames;

#pragma mark - 高级游戏模式（keychain 文件权限位）

/// 读 stat.st_mode & 0x80：无该位 = 已开启
- (BOOL)isGameModeOn;
- (NSString *)gameModeStatusText;          // 给界面直接显示
- (BOOL)setGameModeOn:(BOOL)on error:(NSString *_Nullable *_Nullable)err;

/// 当前 keychain-2.db 的权限（八进制字符串，供诊断）
- (nullable NSString *)keychainModeOctal;

@end

NS_ASSUME_NONNULL_END
