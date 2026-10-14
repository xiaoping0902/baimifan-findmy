//
//  RootViewController.h — 主界面控制台
//
#import <UIKit/UIKit.h>

@interface RootViewController : UIViewController

/// 供其它模块（HUD / 内核链）回报状态，刷新控制台
- (void)refreshStatus;

@end
