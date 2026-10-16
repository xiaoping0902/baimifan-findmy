#import "MFHUDCaptureShieldView.h"

@interface MFHUDSecureField : UITextField
@property (nonatomic, weak) UIView *protectedCanvas;
@end

@implementation MFHUDSecureField
- (BOOL)canBecomeFirstResponder { return NO; }
- (void)layoutSubviews {
    [super layoutSubviews];
    // UITextField normally sizes this to its text rect. HUD coordinates must
    // instead match the entire native panel (including after ball/rotation).
    self.protectedCanvas.frame = self.bounds;
}
@end

static UIView *MFFindSecureCanvas(UIView *view) {
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) containsString:@"CanvasView"]) return child;
        UIView *canvas = MFFindSecureCanvas(child);
        if (canvas) return canvas;
    }
    return nil;
}

@implementation MFHUDCaptureShieldView {
    MFHUDSecureField *_secureField;
}

- (instancetype)initWithFrame:(CGRect)frame error:(NSString **)error {
    if (error) *error = nil;
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        _secureField = [[MFHUDSecureField alloc] initWithFrame:self.bounds];
        _secureField.secureTextEntry = YES;
        _secureField.borderStyle = UITextBorderStyleNone;
        _secureField.backgroundColor = UIColor.clearColor;
        _secureField.textColor = UIColor.clearColor;
        _secureField.tintColor = UIColor.clearColor;
        _secureField.accessibilityElementsHidden = YES;
        _secureField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_secureField];
        [_secureField setNeedsLayout];
        [_secureField layoutIfNeeded];
        UIView *canvas = MFFindSecureCanvas(_secureField);
        if (!canvas) {
            if (error) *error = @"当前系统未提供安全文本画布，无法建立悬浮内容截屏保护。";
            return nil;
        }
        _secureField.protectedCanvas = canvas;
        canvas.userInteractionEnabled = YES;
        canvas.frame = self.bounds;
        _contentView = [[UIView alloc] initWithFrame:canvas.bounds];
        _contentView.backgroundColor = UIColor.clearColor;
        _contentView.opaque = NO;
        _contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [canvas addSubview:_contentView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _secureField.frame = self.bounds;
    [_secureField setNeedsLayout];
    [_secureField layoutIfNeeded];
    _contentView.frame = _secureField.protectedCanvas.bounds;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled ||
        ![self pointInside:point withEvent:event]) return nil;
    // The text field and its canvas are infrastructure, never input targets.
    // Delegate only to the protected content's real controls/overlay geometry.
    CGPoint local = [_contentView convertPoint:point fromView:self];
    UIView *hit = [_contentView hitTest:local withEvent:event];
    return hit == _contentView ? nil : hit;
}
@end
