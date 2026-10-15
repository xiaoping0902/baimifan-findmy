#import <UIKit/UIKit.h>
@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN
/// Receives BKS HID notifications and forwards one primary finger to ImGui.
@interface MFHUDInputBridge : NSObject
- (instancetype)initWithOverlay:(MFOverlayView *)overlay window:(UIWindow *)window;
- (BOOL)installWithError:(NSString *_Nullable *_Nullable)error;
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
