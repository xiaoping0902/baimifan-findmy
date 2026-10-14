//
//  MFProjection.h — 三维世界坐标 → 屏幕二维坐标
//
//  实现依据《读取与绘制_实现全解.md》§5.1（248 字节函数 sub_1001EB750 全解）
//
//  ★ 已证部分（指令级）：
//    · 三个角度 × 0.0174533（常量 dword_100D412F0）
//    · sinf / cosf 展开
//    · 相对位移 dx/dy/dz = 目标 − 相机
//    · 深度 = dx·cosP·cosY + dy·cosP·sinY + dz·sinP      ← 与相机前向点积
//    · 深度 < 0.1（常量 dword_100D4041C）→ 返回哨兵 (-9999, -9999)
//    · 焦距 = tan(FOV × π/360)；FOV ≤ 0 时用 tan(π/4)
//    · 屏幕坐标 = 屏幕中心 + 焦距 × (分量 / 深度)
//
//  ★ 报告没逐条列出「横向分量 / 纵向分量」的确切表达式（只写了这两个词）。
//    本实现按标准相机模型补全：
//      右向量 R = (-sinY,  cosY, 0)
//      上向量 U = (-sinP·cosY, -sinP·sinY, cosP)      （与前向正交，已验算）
//      横向 = dot(d, R)、纵向 = -dot(d, U)            （屏幕 Y 向下，故取负）
//    若真机画面上下/左右镜像，改 MFSignConvention 即可，不用重推。
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 相机的一次采样（每帧刷新）
typedef struct {
    float x, y, z;          // 位置
    float pitch, yaw, roll; // 三个角度（度）
    float fov;              // 视场角（度）
} MFCamera;

/// 屏幕参数
typedef struct {
    float width, height;    // 逻辑尺寸（点）
    float centerX, centerY; // 屏幕中心
    float focal;            // 焦距 = tan(fov·π/360)
} MFScreen;

/// 投影结果
typedef struct {
    float x, y;
    BOOL  valid;            // 深度不足时为 NO
} MFPoint2D;

/// 符号约定开关（真机校准时用；默认全 YES）
typedef struct {
    BOOL negateSide;        // 横向取反
    BOOL negateUp;          // 纵向取反
    BOOL applyRoll;         // 是否应用横滚旋转
} MFSignConvention;

@interface MFProjection : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) MFSignConvention convention;

/// 由屏幕尺寸 + FOV 构造屏幕参数
+ (MFScreen)screenWithSize:(CGSize)size fov:(float)fov;

/// 核心投影（对齐 sub_1001EB750）
+ (MFPoint2D)projectTarget:(const float *)targetXYZ camera:(MFCamera)camera screen:(MFScreen)screen;

/// 实例方法版（带符号约定）
- (MFPoint2D)projectTarget:(const float *)targetXYZ camera:(MFCamera)camera screen:(MFScreen)screen;

/// 世界坐标 → 距离（米）。已证：sqrt(dx²+dy²+dz²) ÷ 100
+ (float)distanceMetersFrom:(const float *)a to:(const float *)b;

/// 自检摘要
- (NSString *)conventionText;

@end

NS_ASSUME_NONNULL_END
