#import "MFHUDTouchRouter.h"
#include <math.h>

@implementation MFHUDTouchRouter {
    __weak id<MFHUDTouchOutput> _output;
    NSNumber *_identity;
}
- (instancetype)initWithOutput:(id<MFHUDTouchOutput>)output {
    if ((self = [super init])) _output = output;
    return self;
}
- (BOOL)hasActiveTouch { return _identity != nil; }
- (BOOL)ownsTouchID:(NSInteger)identity { return _identity && _identity.integerValue == identity; }
- (BOOL)handleTouchID:(NSInteger)identity point:(CGPoint)point
               phase:(MFHUDTouchPhase)phase captureRect:(CGRect)rect {
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) { [self cancelAll]; return NO; }
    if (identity <= 0 || !isfinite(point.x) || !isfinite(point.y)) return NO;
    if (phase == MFHUDTouchBegan) {
        if (_identity) return _identity.integerValue == identity;
        if (!CGRectContainsPoint(rect, point)) return NO;
        _identity = @(identity);
        [_output touchAtPoint:point down:YES];
        return YES;
    }
    if (!_identity || _identity.integerValue != identity) return NO;
    if (phase == MFHUDTouchCancelled) { [self cancelAll]; return YES; }
    BOOL down = phase != MFHUDTouchEnded;
    [_output touchAtPoint:point down:down];
    if (!down) _identity = nil;
    return YES;
}
- (void)cancelAll {
    if (_identity) [_output cancelTouch];
    _identity = nil;
}
@end
