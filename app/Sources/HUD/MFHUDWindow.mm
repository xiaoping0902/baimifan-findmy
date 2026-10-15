#import "MFHUDAppDelegate.h"
#import "MFHUDLog.h"
#import <objc/message.h>

// System/secure flags follow TrollSpeed's HUDMainWindow implementation.
@implementation MFHUDWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

/*
 * ★ 「整面板穿透」时把窗口整体标记为不可命中。
 *
 * 这是窗口服务器层面最快的一条排除路径（M5.64 就是靠它在绘制窗上
 * 让系统日志里的命中次数变成 0）。局部穿透仍由下面的 hitTest 负责 ——
 * 系统对托管窗口的命中判定会落到窗口自己的 hitTest 上。
 *
 * ★ 这里刻意【不引用 MFOverlayView 类型】，改用选择器问一句：
 *   hud_uikit_regressions 只链接 MFHUDWindow.mm（模拟器夹具用普通 UIView
 *   冒充内容视图），一旦引用具体类就会把整条渲染链拖进测试的链接阶段。
 */
- (BOOL)_ignoresHitTest {
    UIView *content = self.interactiveView;
    if (!content) return YES;
    SEL selector = NSSelectorFromString(@"passthroughAll");
    if ([content respondsToSelector:selector])
        return ((BOOL (*)(id, SEL))objc_msgSend)(content, selector);
    return NO;
}

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
     *   穿透    → hitTest 返回 nil，系统把事件交给下层 App
     * 之前没有这条记录，只能靠猜。
     */
    if (hit && sMFHitTestLogged < 12) {
        sMFHitTestLogged++;
        MFHUDLogLine(@"窗口命中：点=(%.0f,%.0f) → 菜单接住（第 %u 次记录）",
                     local.x, local.y, sMFHitTestLogged);
    } else if (!hit && sMFHitTestMissLogged < 12) {
        sMFHitTestMissLogged++;
        MFHUDLogLine(@"窗口穿透：点=(%.0f,%.0f) → 交给下层（第 %u 次记录）",
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
