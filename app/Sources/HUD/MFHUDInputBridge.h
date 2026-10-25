#import <UIKit/UIKit.h>
@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN
/// Receives BKS HID notifications and forwards one primary finger to ImGui.
@interface MFHUDInputBridge : NSObject
- (instancetype)initWithOverlay:(MFOverlayView *)overlay window:(UIWindow *)window;
/// A second, bounded native surface (the island), routed by the same HID owner.
@property (nonatomic, weak, nullable) UIView *auxiliaryView;
@property (nonatomic, copy, nullable) void (^auxiliaryPressHandler)(BOOL pressed);
@property (nonatomic, copy, nullable) void (^auxiliaryActivationHandler)(void);
/// Disable only panel input while it animates or is collapsed. Island stays live.
@property (nonatomic) BOOL menuInputEnabled;
- (BOOL)installWithError:(NSString *_Nullable *_Nullable)error;
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
