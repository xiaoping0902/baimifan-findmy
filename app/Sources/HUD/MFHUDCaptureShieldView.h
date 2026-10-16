#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A persistent secure-text canvas for hosted HUD content. UIKit's private
/// canvas behavior must also be checked on the installed OS with capture tests.
@interface MFHUDCaptureShieldView : UIView
@property (nonatomic, strong, readonly) UIView *contentView;
- (nullable instancetype)initWithFrame:(CGRect)frame
                                error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
