//
//  MFStyle.h — 菜单皮肤（照抄参考项目 小玉源码 jni/src/ui.h 的浅色 iOS 主题）
//
//  取值全部来自参考实现的 GetTheme()：4 套底色 + 白色表面 + 极淡描边 +
//  深色正文 + HSV 主题色（accent）。这里只做「token → ImGuiStyle」的映射，
//  不改任何控件逻辑，所以换肤不会影响交互。
//
#import <Foundation/Foundation.h>
#include "imgui.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    int   theme;        // 0..3，对应参考实现的 4 套底色
    float accentHue;    // 主题色色相 0..1（0.58 ≈ iOS 蓝）
    float alpha;        // 面板不透明度 0.6..1.0
} MFStyleOptions;

/// 返回一份默认值（纯白底、iOS 蓝、不透明度 0.96）——和参考实现一致。
MFStyleOptions MFStyleDefaultOptions(void);

/// 把浅色主题套到 ImGuiStyle（颜色 + 圆角 + 内边距）。
void MFApplyLightStyle(ImGuiStyle *style, MFStyleOptions options);

NS_ASSUME_NONNULL_END
