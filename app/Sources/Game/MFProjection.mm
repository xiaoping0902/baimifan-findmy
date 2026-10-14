//
//  MFProjection.mm — 投影数学（实现）
//
#import "MFProjection.h"
#import "Offsets.h"
#include <math.h>

@implementation MFProjection

+ (instancetype)shared {
    static MFProjection *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[MFProjection alloc] init];
        s.convention = (MFSignConvention){ .negateSide = YES, .negateUp = NO, .applyRoll = YES };
    });
    return s;
}

#pragma mark - 屏幕参数

+ (MFScreen)screenWithSize:(CGSize)size fov:(float)fov {
    MFScreen s;
    s.width   = (float)size.width;
    s.height  = (float)size.height;
    s.centerX = s.width  * 0.5f;
    s.centerY = s.height * 0.5f;
    // 已证：焦距 = tan(FOV × π/360)；FOV ≤ 0 时退化为 tan(π/4)
    s.focal = (fov <= 0.0f) ? tanf((float)M_PI / 4.0f)
                            : tanf(fov * (float)M_PI / 360.0f);
    return s;
}

#pragma mark - 核心投影

+ (MFPoint2D)projectTarget:(const float *)t camera:(MFCamera)c screen:(MFScreen)sc {
    return [[MFProjection shared] projectTarget:t camera:c screen:sc];
}

- (MFPoint2D)projectTarget:(const float *)t camera:(MFCamera)c screen:(MFScreen)sc {
    MFPoint2D out;
    out.x = out.y = kMF_Sentinel;
    out.valid = NO;
    if (!t) return out;

    // 1) 角度 → 弧度（已证常量 0.0174533）
    float P = c.pitch * kMF_Deg2Rad;
    float Y = c.yaw   * kMF_Deg2Rad;
    float R = c.roll  * kMF_Deg2Rad;

    float sinP = sinf(P), cosP = cosf(P);
    float sinY = sinf(Y), cosY = cosf(Y);
    float sinR = sinf(R), cosR = cosf(R);

    // 2) 相对位移
    float dx = t[0] - c.x;
    float dy = t[1] - c.y;
    float dz = t[2] - c.z;

    // 3) 深度 = 与相机前向的点积（已证式子）
    float depth = dx * cosP * cosY + dy * cosP * sinY + dz * sinP;

    // 4) 背后剔除（已证阈值 0.1）
    if (depth < kMF_MinDepth) {
        return out;                     // 哨兵 (-9999, -9999)
    }

    // 5) 横向 / 纵向分量（报告未逐条列出，按标准相机模型补全）
    //    右向量 R = (-sinY, cosY, 0)
    float side = -dx * sinY + dy * cosY;
    //    上向量 U = (-sinP·cosY, -sinP·sinY, cosP)；屏幕 Y 向下 → 取负
    float up   = -( -dx * sinP * cosY - dy * sinP * sinY + dz * cosP );

    if (self.convention.negateSide) side = -side;
    if (self.convention.negateUp)   up   = -up;

    // 横滚：在屏幕平面内旋转 (side, up)
    if (self.convention.applyRoll && (sinR != 0.0f || cosR != 1.0f)) {
        float s2 = side * cosR - up * sinR;
        float u2 = side * sinR + up * cosR;
        side = s2;
        up   = u2;
    }

    // 6) 透视除法 + 屏幕中心
    float inv = sc.focal / depth;
    out.x = sc.centerX + side * inv;
    out.y = sc.centerY + up   * inv;
    out.valid = YES;
    return out;
}

#pragma mark - 距离

+ (float)distanceMetersFrom:(const float *)a to:(const float *)b {
    if (!a || !b) return 0.0f;
    float dx = a[0] - b[0];
    float dy = a[1] - b[1];
    float dz = a[2] - b[2];
    // 已证：sqrt(dx²+dy²+dz²) / 100 → 世界单位是厘米
    return sqrtf(dx * dx + dy * dy + dz * dz) / kMF_WorldUnitToMeter;
}

#pragma mark - 诊断

- (NSString *)conventionText {
    return [NSString stringWithFormat:@"符号约定：横向%@ · 纵向%@ · 横滚%@\n"
            @"常量：°→rad %.7f · 深度阈值 %.2f · 哨兵 %.0f · 单位换算 /%.0f",
            self.convention.negateSide ? @"取反" : @"正向",
            self.convention.negateUp ? @"取反" : @"正向",
            self.convention.applyRoll ? @"启用" : @"忽略",
            kMF_Deg2Rad, kMF_MinDepth, kMF_Sentinel, kMF_WorldUnitToMeter];
}

@end
