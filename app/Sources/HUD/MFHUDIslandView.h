#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A native, compact toggle surface. Its host owns screen placement.
@interface MFHUDIslandView : UIView
@property (nonatomic, copy, nullable) void (^activationHandler)(void);
/// External HID input owns the gesture when enabled; UIKit must not repeat it.
@property (nonatomic, assign) BOOL usesExternalTouchInput;
@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;
@property (nonatomic, assign, readonly, getter=isPressed) BOOL pressed;
+ (CGSize)preferredSize;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)setPressed:(BOOL)pressed animated:(BOOL)animated;
/// Plain system-font text avoids icon-font dependencies for live counters.
- (void)updateRealCount:(NSInteger)real botCount:(NSInteger)bot
             lootCount:(NSInteger)loot cameraValid:(BOOL)cameraValid;
@end

NS_ASSUME_NONNULL_END
