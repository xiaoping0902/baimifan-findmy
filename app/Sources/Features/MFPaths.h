//
//  MFPaths.h — 共用路径与沙盒判定
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 清理目标之一：一个待删条目
@interface MFCleanupItem : NSObject
@property (nonatomic, copy) NSString *path;        // 绝对路径
@property (nonatomic, copy) NSString *name;        // 条目名
@property (nonatomic, copy) NSString *ruleRoot;    // 命中的配置目录
@property (nonatomic, copy) NSString *matchedBy;   // blacklist / default
@property (nonatomic, assign) BOOL isDirectory;
@property (nonatomic, assign) unsigned long long size;   // 字节；目录为 0（不递归统计）
@end

@interface MFPaths : NSObject

/// 关键路径
+ (NSString *)keychainDB;              // /var/Keychains/keychain-2.db
+ (NSString *)lsdIdentifiersPlist;     // com.apple.lsdidentifiers.plist（自动定位）

/// 沙盒豁免自检：能否列出该目录
+ (BOOL)canListDirectory:(NSString *)path
                   count:(nullable NSUInteger *)count
                   error:(NSString *_Nullable *_Nullable)err;

/// 是否具备 root（uid==0）
+ (BOOL)isRoot;

/// 人类可读大小
+ (NSString *)humanSize:(unsigned long long)bytes;

@end

NS_ASSUME_NONNULL_END
