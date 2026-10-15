#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, MFHUDStartupState) {
    MFHUDStartupPending, MFHUDStartupReady, MFHUDStartupFailed, MFHUDStartupExited
};

@interface MFHUDStartupStatus : NSObject
+ (nullable NSString *)currentToken;
+ (nullable NSString *)reportPathForToken:(NSString *)token;
+ (BOOL)writeReport:(NSDictionary *)report token:(NSString *)token error:(NSError **)error;
+ (nullable NSDictionary *)readReportForToken:(NSString *)token;
+ (MFHUDStartupState)stateForReport:(nullable NSDictionary *)report pid:(int)pid
                            token:(NSString *)token processAlive:(BOOL)alive;
@end
NS_ASSUME_NONNULL_END
