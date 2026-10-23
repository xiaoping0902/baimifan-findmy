#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Serialize already collected values only. No reader, kernel, rendering or
/// binding providers are imported or invoked by this writer.
@interface MFHUDPassiveState : NSObject
+ (nullable NSString *)snapshotPathForToken:(NSString *)token directory:(NSString *)directory;
+ (BOOL)writeSnapshot:(NSDictionary *)snapshot token:(NSString *)token
            directory:(NSString *)directory error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
