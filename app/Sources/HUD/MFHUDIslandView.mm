#import "MFHUDIslandView.h"
#import <QuartzCore/QuartzCore.h>
#include <cmath>

@implementation MFHUDIslandView {
    UIView *_statusDot;
    UILabel *_titleLabel;
    UILabel *_actionLabel;
    UIImageView *_chevron;
    UITouch *_trackingTouch;
    CGPoint _touchStart;
    BOOL _touchMoved;
}

+ (CGSize)preferredSize { return CGSizeMake(142.0, 36.0); }

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

    _statusDot = [UIView new];
    _statusDot.userInteractionEnabled = NO;
    _statusDot.backgroundColor = [UIColor colorWithRed:0.49 green:0.91 blue:0.77 alpha:1.0];
    _statusDot.layer.cornerRadius = 2.5;
    _statusDot.layer.shadowColor = _statusDot.backgroundColor.CGColor;
    _statusDot.layer.shadowOpacity = 0.35;
    _statusDot.layer.shadowRadius = 3.0;
    _statusDot.layer.shadowOffset = CGSizeZero;
    [self addSubview:_statusDot];

    _titleLabel = [UILabel new];
    _titleLabel.userInteractionEnabled = NO;
    _titleLabel.text = @"灵动岛";
    _titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor colorWithWhite:0.97 alpha:1.0];
    [self addSubview:_titleLabel];

    _actionLabel = [UILabel new];
    _actionLabel.userInteractionEnabled = NO;
    _actionLabel.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightMedium];
    _actionLabel.textColor = [UIColor colorWithWhite:0.66 alpha:1.0];
    [self addSubview:_actionLabel];

    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    _chevron.userInteractionEnabled = NO;
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    _chevron.tintColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [self addSubview:_chevron];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityIdentifier = @"hud.dynamicIsland";
    self.accessibilityLabel = @"灵动岛";
    [self setExpanded:NO animated:NO];
}

- (CGSize)intrinsicContentSize { return [[self class] preferredSize]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = CGRectGetWidth(self.bounds);
    const CGFloat midY = CGRectGetMidY(self.bounds);
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                   cornerRadius:self.layer.cornerRadius].CGPath;
    _statusDot.frame = CGRectMake(13.0, midY - 2.5, 5.0, 5.0);
    const CGFloat labelWidth = MAX(0.0, width - 51.0);
    _titleLabel.frame = CGRectMake(26.0, midY - 13.0, labelWidth, 13.0);
    _actionLabel.frame = CGRectMake(26.0, midY + 1.0, labelWidth, 11.0);
    _chevron.frame = CGRectMake(width - 23.0, midY - 4.0, 9.0, 8.0);
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded && _actionLabel.text) return;
    _expanded = expanded;
    self.accessibilityValue = expanded ? @"已展开" : @"已收起";
    self.accessibilityHint = expanded ? @"轻点收起面板" : @"轻点展开面板";
    void (^update)(void) = ^{
        self->_actionLabel.text = expanded ? @"轻点收起" : @"轻点展开";
        self->_chevron.transform = expanded ? CGAffineTransformMakeRotation((CGFloat)M_PI) :
                                             CGAffineTransformIdentity;
    };
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) {
        update();
        return;
    }
    [UIView transitionWithView:_actionLabel duration:0.18
                      options:UIViewAnimationOptionTransitionCrossDissolve |
                              UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:update completion:nil];
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
