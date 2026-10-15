#import "MFHUDWindowHost.h"
#include <string.h>

@protocol MFRemoteLayerContext <NSObject>
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
- (instancetype)initRemoteWithOptions:(NSDictionary *)options;
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic) BOOL secure;
@property (nonatomic, readonly) uint32_t contextId;
@end

@implementation MFHUDWindowHost {
    CALayer *_layer;
    Class _contextClass;
    Class _hostingClass;
    double _level;
}

- (instancetype)initWithLayer:(CALayer *)layer nativeContextID:(uint32_t)contextID
                        level:(double)level contextClass:(Class)contextClass
                 hostingClass:(Class)hostingClass {
    if ((self = [super init])) {
        _layer = layer;
        _contextID = contextID;
        _level = level;
        _contextClass = contextClass;
        _hostingClass = hostingClass;
    }
    return self;
}

- (BOOL)registerWithError:(NSString **)error {
    if (error) *error = nil;
    if (_hostingController) return YES;
    @try {
        if (!_hostingClass) {
            if (error) *error = @"SBSAccessibilityWindowHostingController 不可用";
            return NO;
        }
        if (_contextID == 0) {
            // UIKit may already own a nonzero native context. Only create a
            // remote context when the caller has no native one, once per owner.
            if (!_context) {
                Class<MFRemoteLayerContext> cls = (Class<MFRemoteLayerContext>)_contextClass;
                id<MFRemoteLayerContext> context = nil;
                if ([cls respondsToSelector:@selector(remoteContextWithOptions:)]) {
                    context = [cls remoteContextWithOptions:@{}];
                } else if ([(Class)cls instancesRespondToSelector:@selector(initRemoteWithOptions:)]) {
                    context = [[(Class)cls alloc] initRemoteWithOptions:@{}];
                }
                if (!context || ![context respondsToSelector:@selector(setLayer:)] ||
                    ![context respondsToSelector:@selector(contextId)]) {
                    if (error) *error = @"无法创建支持 layer/contextId 的远程 CAContext";
                    return NO;
                }
                _context = context;
                context.layer = _layer;
                if ([context respondsToSelector:@selector(setSecure:)]) context.secure = YES;
            }
            _contextID = [(id<MFRemoteLayerContext>)_context contextId];
            if (_contextID == 0) {
                if (error) *error = @"远程 CAContext 的 contextId 为 0，窗口未提交托管";
                return NO;
            }
        }

        id controller = [[_hostingClass alloc] init];
        SEL selector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        NSMethodSignature *signature = [controller methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 4 ||
            strcmp([signature getArgumentTypeAtIndex:2], @encode(unsigned int)) != 0 ||
            strcmp([signature getArgumentTypeAtIndex:3], @encode(double)) != 0) {
            if (error) *error = @"窗口托管接口不存在或参数签名不兼容";
            return NO;
        }
        unsigned int cid = _contextID;
        double level = _level;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = controller;
        call.selector = selector;
        [call setArgument:&cid atIndex:2];
        [call setArgument:&level atIndex:3];
        [call invoke];
        // Registration is a void private API, so this proves submission only.
        // Retain its receiver for the full lifetime of the displayed window.
        _hostingController = controller;
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSString stringWithFormat:@"窗口托管异常：%@ / %@",
                             exception.name, exception.reason ?: @""];
        return NO;
    }
}
@end
