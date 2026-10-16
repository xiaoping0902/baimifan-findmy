#import "MFHUDAppDelegate.h"
#import "MFHUDLog.h"
#import <objc/message.h>

// System/secure flags follow TrollSpeed's HUDMainWindow implementation.
@implementation MFHUDWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

// UIKit consults this while super initializes the native window context.
// The menu role must remain interactive even before interactiveView exists.
- (BOOL)_ignoresHitTest { return NO; }

/// 命中判定日志有上限：真机上只看「系统到底有没有来问过我们」。
static unsigned sMFHitTestLogged = 0;
static unsigned sMFHitTestMissLogged = 0;

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled) return nil;
    UIView *content = self.interactiveView;
    if (!content) return nil;

    CGPoint local = [content convertPoint:point fromView:self];
    UIView *hit = [content hitTest:local withEvent:event];

    /*
     * 穿透是否真的生效，只能靠这条日志判断：
     *   命中    → 菜单接住，事件不会给下层
     *   未命中  → UIKit 返回 nil；跨进程重新分发仍需真机验证
     * 之前没有这条记录，只能靠猜。
     */
    if (hit && sMFHitTestLogged < 12) {
        sMFHitTestLogged++;
        MFHUDLogLine(@"窗口命中：点=(%.0f,%.0f) → 菜单接住（第 %u 次记录）",
                     local.x, local.y, sMFHitTestLogged);
    } else if (!hit && sMFHitTestMissLogged < 12) {
        sMFHitTestMissLogged++;
        MFHUDLogLine(@"窗口未命中：点=(%.0f,%.0f) → UIKit 返回 nil（第 %u 次记录）",
                     local.x, local.y, sMFHitTestMissLogged);
    }
    return hit;
}

@end

@implementation MFHUDDrawingWindow
// The drawing role is an invariant, not a flag set after [super initWithFrame:].
// The original DrawingWindow also returns YES directly from _ignoresHitTest.
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

@implementation MFHUDSharedTouchWindow
// Keep system touch targeting separate from the HID observer's menu geometry.
// Setting this after super init can leave an already-interactive native context.
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end
