#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// The unscoped name is retained only for stopping a legacy HUD PID record.
extern NSString *const MFHUDExitNotificationName;
/// Durable process identity; an exit request never removes this record.
extern NSString *const MFHUDPIDFilePath;

@interface MFHUDControl : NSObject
/// HUD callers address their own session; console callers address the saved one.
+ (void)requestExit;
+ (BOOL)requestExitForPID:(pid_t)pid token:(nullable NSString *)token error:(NSError **)error;
/// Install before UIKit. Reception and the hard deadline run off the main queue;
/// the cleanup handler is delivered on main.
+ (void)watchForExitRequest:(dispatch_block_t)handler;
+ (void)stopWatching;
+ (BOOL)exitRequested;
+ (BOOL)watchdogSawOwnPID;
/// Legacy decimal PID files are normalized to {pid}.
+ (nullable NSDictionary *)readPIDRecord;
+ (BOOL)writePIDRecord:(NSDictionary *)record error:(NSError **)error;
+ (void)removePIDRecordIfMatching:(NSDictionary *)record;
/// Short recursive file lock for spawn/check/write and CAS cleanup. Never hold
/// it while waiting for UIKit, startup readiness or process exit.
+ (BOOL)withPIDRecordLock:(dispatch_block_t)operation;
@end
NS_ASSUME_NONNULL_END
