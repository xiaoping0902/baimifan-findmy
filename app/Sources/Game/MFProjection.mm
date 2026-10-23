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
        // UE 的 +Y 已是右向，up 分量在下面已转换为屏幕 Y 向下。
        // 横滚保留显式开关，默认不应用。
        s.convention = (MFSignConvention){ .negateSide = NO, .negateUp = NO, .applyRoll = NO };
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
    s.focal = 0.0f;
    if (!isfinite(s.width) || !isfinite(s.height) || s.width <= 0 || s.height <= 0 ||
        !isfinite(fov) || fov <= 0 || fov >= 180) return s;
    // 水平 FOV 的焦距使用屏幕半宽，横纵两个方向共用这个逻辑点尺度。
    s.focal = s.centerX / tanf(fov * (float)M_PI / 360.0f);
    if (!isfinite(s.focal) || s.focal <= 0) s.focal = 0.0f;
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
    if (!t || !isfinite(t[0]) || !isfinite(t[1]) || !isfinite(t[2]) ||
        !isfinite(c.x) || !isfinite(c.y) || !isfinite(c.z) ||
        !isfinite(c.pitch) || !isfinite(c.yaw) || !isfinite(c.roll) ||
        !isfinite(c.fov) || c.fov <= 0 || c.fov >= 180 ||
        !isfinite(sc.width) || !isfinite(sc.height) || sc.width <= 0 || sc.height <= 0 ||
        !isfinite(sc.centerX) || !isfinite(sc.centerY) ||
        !isfinite(sc.focal) || sc.focal <= 0) return out;

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

    // 4) 背后/近面剔除，并拒绝有限输入在中间计算中产生的溢出。
    if (!isfinite(depth) || !(depth >= kMF_MinDepth)) {
        return out;                     // 哨兵 (-9999, -9999)
    }

    // 5) UE 相机横向 / 屏幕纵向分量
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
    float x = sc.centerX + side * inv;
    float y = sc.centerY + up   * inv;
    if (!isfinite(x) || !isfinite(y)) return out;
    out.x = x;
    out.y = y;
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
