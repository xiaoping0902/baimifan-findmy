//
//  MFDrawingLayer.h — 透明绘制层（ESP）
//
//  挂在 DrawingWindow 的 MFOverlayView 上，每帧：
//    ① 读相机 → ② 读实体/物资 → ③ 投影 → ④ 用 ImGui DrawList 画出来
//
//  绘制内容对照《白米饭补充分析》§4 的菜单项：
//    人机显示 / 名字 / 头甲 / 血量 / 距离 / 队伍 / 射线 / 手持 / 骨骼
//    物资 / 盒子 / 物资名字 / 统计窗口
//
//  ⚠️ 偏移未校准前：reader 读不到相机就会整帧跳过，不会画错东西。
//     校准入口见 Game/Offsets.h + MFGameReader 的
//     rootObjectBase / entityArrayBase / lootArrayBase。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN

@interface MFDrawingLayer : NSObject

@property (nonatomic, weak, nullable) MFOverlayView *overlay;

/// 全局开关（与菜单的「总开关」联动）
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)enabled;

/// 本帧统计（供菜单/日志显示）
@property (nonatomic, readonly) NSUInteger lastEntityCount;
@property (nonatomic, readonly) NSUInteger lastLootCount;
@property (nonatomic, readonly) BOOL lastCameraOK;

/// 诊断：一帧的完整读数转储（供真机校准看偏移对不对）
- (NSString *)dumpFrameWithSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
