#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// HUD content defaults to an ordinary, capturable view. Capture protection
/// can be explicitly enabled using UIKit's secure-text canvas.
@interface MFHUDCaptureShieldView : UIView
@property (nonatomic, strong, readonly) UIView *contentView;
@property (nonatomic, assign, readonly) BOOL captureProtectionEnabled;
- (BOOL)setCaptureProtectionEnabled:(BOOL)enabled
                             error:(NSString *_Nullable *_Nullable)error;
- (nullable instancetype)initWithFrame:(CGRect)frame
                                error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
