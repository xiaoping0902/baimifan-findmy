//
//  MFMenuPanel.h — 七页签面板接入层
//
//  渲染实体全部来自 UIPort/（原样搬运的 ui.h / ios_ui.h / ios_pages.h）：
//    · RenderUI       —— 面板外框、分页条、滚动、缩放
//    · ios::DrawPage  —— 七个页面（首页/绘制/自瞄/追踪/物资/外观/设置）
//
//  这一层只做三件事：把游戏数据喂进 UIState、把 UIState 的改动写回 MFSettings、
//  把「哪些像素能点」上报给 MFOverlayView。
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include "imgui.h"

@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN

/// 每帧调用一次（在 ImGui 帧内、overlay 的 buildUI 阶段）
void MFMenuPanelRender(MFOverlayView *overlay, ImVec2 screen);

/// Compute the native host size from the full logical screen, and retain that
/// orientation for subsequent rendering into the host's local viewport.
CGSize MFMenuPanelPreferredSize(CGSize logicalScreen);

/// Called once when a size control changes the requested scale.
void MFMenuPanelSetPresentationChangeHandler(void (^ _Nullable handler)(void));

/// Native island center in logical screen coordinates, also used by tracer rays.
ImVec2 MFMenuPanelIslandCenter(ImVec2 screen);
void MFMenuPanelSetIslandCenter(CGPoint center);

/// 展开/收起（供 MFMenuUI 的 collapsed 状态驱动）
void MFMenuPanelSetExpanded(BOOL expanded);
BOOL MFMenuPanelExpanded(void);
BOOL MFMenuPanelConsumeExitRequest(void);

/// 绘制层每帧把统计塞进来：真人 / 人机 / 物资 / 相机是否正常 / 观战者
void MFMenuPanelReportStats(int real, int bot, int loot, BOOL cameraOK, int observers);

NS_ASSUME_NONNULL_END
