#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns one window's layer context and SpringBoard hosting controller together.
/// A remote context publishes the layer tree directly; it is never bound back
/// into UIKit's scene/event-deferring machinery.
@interface MFHUDWindowHost : NSObject
@property (nonatomic, readonly) uint32_t contextID;
@property (nonatomic, strong, readonly, nullable) id context;
@property (nonatomic, strong, readonly, nullable) id hostingController;
- (instancetype)initWithLayer:(CALayer *)layer
              nativeContextID:(uint32_t)contextID
                        level:(double)level
                 contextClass:(nullable Class)contextClass
                 hostingClass:(nullable Class)hostingClass;
- (BOOL)registerWithError:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
