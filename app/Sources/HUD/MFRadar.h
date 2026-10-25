//
//  MFRadar.h — 圆形雷达（移植自参考项目 radar.h 的布局与投影）
//
//  设计来源：小玉源码 jni/src/radar.h
//    · ComputeRadarLayout  —— 按屏幕比例算圆心/半径，短边自适应
//    · ProjectRadarOffset  —— 世界坐标差按相机 yaw 旋转，"前方朝上"
//    · RenderRadarBase     —— 底盘 + 两圈网格 + 十字 + 对角线 + 方位三角 + N/E/S/W + 量程
//
//  与参考实现的差异：
//    · 只保留玩家雷达（迫击炮弹道那套不在本次范围）
//    · 文字用 ImGui 默认字体，字号随半径缩放
//    · 光点颜色由调用方给，不在雷达内部做队伍判断
//
#import <Foundation/Foundation.h>
#include "imgui.h"

NS_ASSUME_NONNULL_BEGIN

/// 雷达配置（每帧由绘制层填）
typedef struct {
    float selfX, selfY;     // 自己的世界坐标（cm，UE 单位）
    float yawDeg;           // 相机偏航（度，0=+X，90=+Y）
    float rangeM;           // 量程（米）
    float xRatio;           // 圆心 X 占屏幕宽比例
    float yRatio;           // 圆心 Y 占屏幕高比例
    float radiusRatio;      // 半径占屏幕短边比例
    BOOL  northUp;          // YES = 北朝上（不跟视角），NO = 前方朝上
} MFRadarConfig;

/// 一个光点
typedef struct {
    float x, y;             // 目标世界坐标（cm）
    float distM;            // 到自己的距离（米），用于标注
    ImU32 color;            // 光点颜色
    BOOL  isBot;            // 人机 → 小一号的点
} MFRadarBlip;

/**
 * 画一帧雷达。blips 由调用方每帧组装；count <= 0 时只画底盘。
 * screen 为当前视口尺寸（点）。内部会做所有边界钳制，不会越界绘制。
 */
void MFRadarRender(ImDrawList *dl, ImVec2 screen,
                   const MFRadarConfig *cfg,
                   const MFRadarBlip *blips, int count);

NS_ASSUME_NONNULL_END
