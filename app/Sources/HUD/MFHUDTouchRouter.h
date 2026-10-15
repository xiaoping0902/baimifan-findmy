#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, MFHUDTouchPhase) {
    MFHUDTouchBegan, MFHUDTouchMoved, MFHUDTouchEnded, MFHUDTouchCancelled
};
@protocol MFHUDTouchOutput <NSObject>
- (void)touchAtPoint:(CGPoint)point down:(BOOL)down;
- (void)cancelTouch;
@end

/// Own one finger from an inside begin through lift/cancel, even outside bounds.
/// This controls input to ImGui; OS pass-through is the window host's job.
@interface MFHUDTouchRouter : NSObject
@property (nonatomic, readonly) BOOL hasActiveTouch;
- (BOOL)ownsTouchID:(NSInteger)identity;
- (instancetype)initWithOutput:(id<MFHUDTouchOutput>)output;
- (BOOL)handleTouchID:(NSInteger)identity point:(CGPoint)point
               phase:(MFHUDTouchPhase)phase captureRect:(CGRect)rect;
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
