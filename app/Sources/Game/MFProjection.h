//
//  MFProjection.h — 三维世界坐标 → 屏幕二维坐标
//
//  UE 相机模型：零俯仰/偏航时朝 +X 看，+Y 在右侧，+Z 在上方。
//    前向 F = (cosP·cosY, cosP·sinY, sinP)
//    右向 R = (-sinY, cosY, 0)
//    上向 U = (-sinP·cosY, -sinP·sinY, cosP)
//  相对位移 d = 目标 − 相机，深度 = dot(d, F)。
//  FOV 为水平视场角；焦距 = (屏幕宽 / 2) / tan(FOV × π/360)。
//  屏幕 X = 中心 X + dot(d, R) × 焦距 / 深度。
//  屏幕 Y = 中心 Y − dot(d, U) × 焦距 / 深度（屏幕 Y 向下）。
//  深度 < 0.1、无效视场/尺寸或非有限输入输出返回哨兵 (-9999, -9999)。
//  MFSignConvention 保留显式符号翻转与横滚选项。
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 相机的一次采样（每帧刷新）
typedef struct {
    float x, y, z;          // 位置
    float pitch, yaw, roll; // 三个角度（度）
    float fov;              // 水平视场角（度），必须在 (0, 180) 内
} MFCamera;

/// 屏幕参数
typedef struct {
    float width, height;    // 逻辑尺寸（点）
    float centerX, centerY; // 屏幕中心
    float focal;            // 逻辑点单位焦距 = (width/2) / tan(fov·π/360)；0 表示无效
} MFScreen;

/// 投影结果
typedef struct {
    float x, y;
    BOOL  valid;            // 深度不足、参数无效或输出非有限时为 NO
} MFPoint2D;

/// 符号约定开关（默认全 NO，对应 UE 右向及屏幕 Y 向下）
typedef struct {
    BOOL negateSide;        // 横向取反
    BOOL negateUp;          // 纵向取反
    BOOL applyRoll;         // 是否应用横滚旋转
} MFSignConvention;

@interface MFProjection : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) MFSignConvention convention;

/// 由逻辑屏幕尺寸 + 水平 FOV 构造屏幕参数；无效输入的 focal 为 0
+ (MFScreen)screenWithSize:(CGSize)size fov:(float)fov;

/// 核心投影（使用共享实例的符号约定）
+ (MFPoint2D)projectTarget:(const float *)targetXYZ camera:(MFCamera)camera screen:(MFScreen)screen;

/// 实例方法版（带符号约定）
- (MFPoint2D)projectTarget:(const float *)targetXYZ camera:(MFCamera)camera screen:(MFScreen)screen;

/// 世界坐标 → 距离（米）。已证：sqrt(dx²+dy²+dz²) ÷ 100
+ (float)distanceMetersFrom:(const float *)a to:(const float *)b;

/// 自检摘要
- (NSString *)conventionText;

@end

NS_ASSUME_NONNULL_END
