#import "MFHUDAppDelegate.h"

// System/secure flags follow TrollSpeed's HUDMainWindow implementation.
@implementation MFHUDWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_ignoresHitTest { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled) return nil;
    UIView *content = self.interactiveView;
    if (!content) return nil;
    return [content hitTest:[content convertPoint:point fromView:self] withEvent:event];
}
@end

@implementation MFHUDDrawingWindow
// The drawing role is an invariant, not a flag set after [super initWithFrame:].
// The original DrawingWindow also returns YES directly from _ignoresHitTest.
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end
