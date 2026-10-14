//
//  MFKeychain.mm — keychain-2.db 那条线（实现）
//
#import "MFKeychain.h"
#import "MFPaths.h"
#import <sqlite3.h>
#import <sys/stat.h>
#import <unistd.h>
#include <errno.h>
#include <string.h>

/// iOS 钥匙串的表（原实现用 queryDataInTablesWithCombinedString: 遍历多张表）
static NSArray<NSString *> *MFKeychainTables(void) {
    static NSArray *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = @[ @"genp", @"inet", @"cert", @"keys" ]; });
    return t;
}

/// 属主写位（stat.st_mode & 0x80）—— 原实现读的就是这一位
static const mode_t MF_S_IWUSR = 0x80;

@implementation MFKeychainResult
- (instancetype)init {
    if ((self = [super init])) {
        _matchedPerTable = [NSMutableDictionary dictionary];
        _deletedPerTable = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@implementation MFKeychain

+ (instancetype)shared {
    static MFKeychain *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFKeychain alloc] init]; });
    return s;
}

+ (NSArray<NSString *> *)gameBundleIDs {
    // 分析已验证：CFString 长度 0x14/0x18/0x12/0x16 逐个吻合
    return @[
        @"com.tencent.tmgp.dfm",      // 三角洲行动
        @"com.tencent.tmgp.pubgmhd",  // 和平精英
        @"com.tencent.mf.uam",        // 暗区突围
        @"com.tencent.tmgp.codev",    // codev
    ];
}

#pragma mark - SQLite 公共

/// 打开 keychain-2.db。失败返回 NULL，err 带原因
static sqlite3 *MFOpenKeychain(NSString **err) {
    NSString *path = [MFPaths keychainDB];
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.fileSystemRepresentation, &db,
                             SQLITE_OPEN_READWRITE, NULL);
    if (rc != SQLITE_OK) {
        if (err) {
            *err = [NSString stringWithFormat:@"sqlite3_open 失败(rc=%d): %s",
                    rc, db ? sqlite3_errmsg(db) : "db=nil"];
        }
        if (db) { sqlite3_close(db); }
        return NULL;
    }
    return db;
}

#pragma mark - 清理 Key

- (MFKeychainResult *)countForBundleID:(NSString *)bundleID {
    MFKeychainResult *res = [[MFKeychainResult alloc] init];
    res.bundleID = bundleID;

    NSString *err = nil;
    sqlite3 *db = MFOpenKeychain(&err);
    if (!db) { res.error = err; return res; }

    for (NSString *table in MFKeychainTables()) {
        // 原实现： DELETE FROM <表> WHERE agrp like '%%<bundleID>%%'
        NSString *sql = [NSString stringWithFormat:
                         @"SELECT COUNT(*) FROM %@ WHERE agrp LIKE '%%%@%%'", table, bundleID];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            NSLog(@"[MF][Keychain] prepare 失败(%@): %s", table, sqlite3_errmsg(db));
            continue;
        }
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            int n = sqlite3_column_int(stmt, 0);
            res.matchedPerTable[table] = @(n);
            res.totalMatched += n;
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return res;
}

- (MFKeychainResult *)deleteForBundleID:(NSString *)bundleID {
    MFKeychainResult *res = [[MFKeychainResult alloc] init];
    res.bundleID = bundleID;

    NSString *err = nil;
    sqlite3 *db = MFOpenKeychain(&err);
    if (!db) { res.error = err; return res; }

    for (NSString *table in MFKeychainTables()) {
        NSString *countSQL = [NSString stringWithFormat:
                              @"SELECT COUNT(*) FROM %@ WHERE agrp LIKE '%%%@%%'", table, bundleID];
        sqlite3_stmt *stmt = NULL;
        int before = 0;
        if (sqlite3_prepare_v2(db, countSQL.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) before = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }
        if (before == 0) continue;

        NSString *delSQL = [NSString stringWithFormat:
                            @"DELETE FROM %@ WHERE agrp LIKE '%%%@%%'", table, bundleID];
        char *sqlErr = NULL;
        int rc = sqlite3_exec(db, delSQL.UTF8String, NULL, NULL, &sqlErr);
        if (rc == SQLITE_OK) {
            res.matchedPerTable[table] = @(before);
            res.deletedPerTable[table] = @(before);
            res.totalMatched += before;
            res.totalDeleted += before;
            NSLog(@"[MF][Keychain] %@ 删除 %d 条 (bundleID=%@)", table, before, bundleID);
        } else {
            NSLog(@"[MF][Keychain] %@ DELETE 失败: %s", table, sqlErr ?: "?");
            if (sqlErr) sqlite3_free(sqlErr);
        }
    }
    sqlite3_close(db);
    return res;
}

- (NSArray<MFKeychainResult *> *)countForAllGames {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *bid in [MFKeychain gameBundleIDs]) {
        [out addObject:[self countForBundleID:bid]];
    }
    return out;
}

#pragma mark - 高级游戏模式

- (nullable NSString *)keychainModeOctal {
    struct stat st;
    const char *p = [MFPaths keychainDB].fileSystemRepresentation;
    if (stat(p, &st) != 0) return nil;
    return [NSString stringWithFormat:@"%03o", st.st_mode & 0777];
}

- (BOOL)isGameModeOn {
    struct stat st;
    const char *p = [MFPaths keychainDB].fileSystemRepresentation;
    if (stat(p, &st) != 0) {
        // 分析已证：stat 失败也返回 false → 界面会显示「已开启」，这个标签本身不代表修改成功
        return YES;
    }
    return (st.st_mode & MF_S_IWUSR) == 0;
}

- (NSString *)gameModeStatusText {
    NSString *mode = [self keychainModeOctal];
    if ([self isGameModeOn]) {
        return [NSString stringWithFormat:@"✓ 高级游戏模式已开启（权限 %@）", mode ?: @"?"];
    }
    return [NSString stringWithFormat:@"高级游戏模式已关闭（权限 %@）", mode ?: @"?"];
}

- (BOOL)setGameModeOn:(BOOL)on error:(NSString **)err {
    NSString *path = [MFPaths keychainDB];
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        if (err) *err = [NSString stringWithFormat:@"stat 失败 errno=%d", errno];
        return NO;
    }
    mode_t cur = st.st_mode & 07777;
    mode_t want = on ? (cur & ~MF_S_IWUSR)      // 开启 = 清除属主写位
                     : (cur | MF_S_IWUSR);      // 关闭 = 恢复属主写位

    if (chmod(path.fileSystemRepresentation, want) != 0) {
        if (err) {
            *err = [NSString stringWithFormat:@"chmod(%03o→%03o) 失败 errno=%d (%s)",
                    cur, want, errno, strerror(errno)];
        }
        return NO;
    }
    NSLog(@"[MF][Keychain] 游戏模式 %@：%03o → %03o", on ? @"开" : @"关", cur, want);
    return YES;
}

@end
