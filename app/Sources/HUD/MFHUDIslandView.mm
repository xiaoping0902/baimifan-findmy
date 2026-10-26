#import "MFHUDIslandView.h"
#import <QuartzCore/QuartzCore.h>

@implementation MFHUDIslandView {
    UILabel *_realLabel;
    UILabel *_botLabel;
    UITouch *_trackingTouch;
    CGPoint _touchStart;
    BOOL _touchMoved;
    NSInteger _realCount, _botCount;
    BOOL _cameraValid;
}

+ (CGSize)preferredSize { return CGSizeMake(132.0, 36.0); }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) [self configureIsland];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) [self configureIsland];
    return self;
}

- (void)configureIsland {
    self.opaque = NO;
    self.backgroundColor = [UIColor colorWithRed:0.035 green:0.042 blue:0.052 alpha:1.0];
    self.multipleTouchEnabled = NO;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.2;
    self.layer.shadowRadius = 5.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 2.0);

    _realLabel = [UILabel new];
    _realLabel.userInteractionEnabled = NO;
    _realLabel.font = [UIFont monospacedDigitSystemFontOfSize:18.0 weight:UIFontWeightBold];
    _realLabel.textColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    _realLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_realLabel];

    _botLabel = [UILabel new];
    _botLabel.userInteractionEnabled = NO;
    _botLabel.font = _realLabel.font;
    _botLabel.textColor = UIColor.whiteColor;
    _botLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_botLabel];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityIdentifier = @"hud.dynamicIsland";
    self.accessibilityLabel = @"小玉灵动岛";
    [self setExpanded:NO animated:NO];
}

- (CGSize)intrinsicContentSize { return [[self class] preferredSize]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = CGRectGetWidth(self.bounds);
    const CGFloat height = CGRectGetHeight(self.bounds);
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                   cornerRadius:self.layer.cornerRadius].CGPath;
    const CGFloat inset = 12.0, gap = 8.0;
    const CGFloat labelWidth = MAX(0.0, (width - 2.0 * inset - gap) * 0.5);
    _realLabel.frame = CGRectMake(inset, 0.0, labelWidth, height);
    _botLabel.frame = CGRectMake(inset + labelWidth + gap, 0.0, labelWidth, height);
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded && _realLabel.text) return;
    _expanded = expanded;
    self.accessibilityHint = expanded ? @"轻点收起面板" : @"轻点展开面板";
    [self updateLabels];
}

- (void)updateLabels {
    NSString *state = _expanded ? @"已展开" : @"已收起";
    const NSInteger real = _cameraValid ? _realCount : 0;
    const NSInteger bot = _cameraValid ? _botCount : 0;
    _realLabel.text = [NSString stringWithFormat:@"%ld", (long)real];
    _botLabel.text = [NSString stringWithFormat:@"%ld", (long)bot];
    self.accessibilityValue = [NSString stringWithFormat:@"%@%@，真人%ld，人机%ld",
                               state, _cameraValid ? @"" : @"，等待画面", (long)real, (long)bot];
}

- (void)updateRealCount:(NSInteger)real botCount:(NSInteger)bot
           cameraValid:(BOOL)cameraValid {
    real = MAX(0, MIN(real, 999)); bot = MAX(0, MIN(bot, 999));
    if (_realLabel.text && _realCount == real && _botCount == bot && _cameraValid == cameraValid) return;
    _realCount = real; _botCount = bot; _cameraValid = cameraValid;
    [self updateLabels];
}

- (void)setPressed:(BOOL)pressed animated:(BOOL)animated {
    if (_pressed == pressed && animated) return;
    _pressed = pressed;
    const BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    void (^update)(void) = ^{
        self.transform = pressed && !reduceMotion ? CGAffineTransformMakeScale(0.965, 0.965) :
                                                   CGAffineTransformIdentity;
        self.backgroundColor = pressed ? [UIColor colorWithRed:0.10 green:0.115 blue:0.13 alpha:1.0] :
                                         [UIColor colorWithRed:0.035 green:0.042 blue:0.052 alpha:1.0];
    };
    if (!animated || reduceMotion) {
        [self.layer removeAllAnimations];
        update();
        return;
    }
    [UIView animateWithDuration:pressed ? 0.16 : 0.30 delay:0.0
         usingSpringWithDamping:0.76 initialSpringVelocity:0.2
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:update completion:nil];
}

- (void)setUsesExternalTouchInput:(BOOL)usesExternalTouchInput {
    if (_usesExternalTouchInput == usesExternalTouchInput) return;
    _usesExternalTouchInput = usesExternalTouchInput;
    [self cancelTracking];
}

- (void)cancelTracking {
    _trackingTouch = nil;
    _touchMoved = NO;
    [self setPressed:NO animated:NO];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self cancelTracking];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_usesExternalTouchInput || _trackingTouch) return;
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint point = [touch locationInView:self];
    if (![self pointInside:point withEvent:event]) return;
    _trackingTouch = touch;
    _touchStart = point;
    _touchMoved = NO;
    [self setPressed:YES animated:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_usesExternalTouchInput || !_trackingTouch || ![touches containsObject:_trackingTouch]) return;
    CGPoint point = [_trackingTouch locationInView:self];
    CGFloat dx = point.x - _touchStart.x, dy = point.y - _touchStart.y;
    if (dx * dx + dy * dy >= 64.0) _touchMoved = YES;
    [self setPressed:!_touchMoved && [self pointInside:point withEvent:event] animated:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_usesExternalTouchInput || !_trackingTouch || ![touches containsObject:_trackingTouch]) return;
    CGPoint point = [_trackingTouch locationInView:self];
    const BOOL activate = !_touchMoved && [self pointInside:point withEvent:event];
    _trackingTouch = nil;
    _touchMoved = NO;
    [self setPressed:NO animated:YES];
    if (activate && self.activationHandler) self.activationHandler();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_trackingTouch || ![touches containsObject:_trackingTouch]) return;
    [self cancelTracking];
}

- (BOOL)accessibilityActivate {
    if (self.hidden || !self.userInteractionEnabled || self.alpha <= 0.01 || !self.activationHandler) return NO;
    self.activationHandler();
    return YES;
}

@end
