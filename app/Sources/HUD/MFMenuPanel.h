//
//  MFMenuPanel.h — 小玉原版面板（灵动岛 + 七页签）接入层
//
//  渲染实体全部来自 UIPort/（原样搬运的 ui.h / ios_ui.h / ios_pages.h）：
//    · ios::RenderUI  —— 面板外框、分页条、滚动、缩放、灵动岛
//    · ios::DrawPage  —— 七个页面（首页/绘制/自瞄/追踪/物资/外观/设置）
//
//  这一层只做三件事：把游戏数据喂进 UIState、把 UIState 的改动写回 MFSettings、
//  把「哪些像素能点」上报给 MFOverlayView。
//
#import <Foundation/Foundation.h>
#include "imgui.h"

@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN

/// 每帧调用一次（在 ImGui 帧内、overlay 的 buildUI 阶段）
void MFMenuPanelRender(MFOverlayView *overlay, ImVec2 screen);

/// 灵动岛中心（屏幕坐标）—— 射线以此为起点，和原版一致
ImVec2 MFMenuPanelIslandCenter(ImVec2 screen);

/// 展开/收起（供 MFMenuUI 的 collapsed 状态驱动）
void MFMenuPanelSetExpanded(BOOL expanded);
BOOL MFMenuPanelExpanded(void);

/// 绘制层每帧把统计塞进来：真人 / 人机 / 物资 / 相机是否正常 / 观战者
void MFMenuPanelReportStats(int real, int bot, int loot, BOOL cameraOK, int observers);

NS_ASSUME_NONNULL_END
