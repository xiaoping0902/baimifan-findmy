//
//  MFSettings.h — 配置模型
//
//  字段对照《白米饭补充分析-启动窗口与功能.md》§4 已恢复的菜单项：
//    绘制开关 / 物资与盒子 / 物资筛选 / 绘制范围 / 背敌提示 / 外观 / 颜色 / 模式
//
//  持久化：对齐原实现「Menu 的 saveSettingsToPlist/loadSettingsFromPlist」，
//  落到 App 自己的 Documents/mf_settings.plist（原版实际路径未证，这里用应用容器内路径）
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 颜色槽

typedef NS_ENUM(NSInteger, MFColorSlot) {
    MFColorSlotPersonInfo = 0,   // 人物信息
    MFColorSlotLootLow,          // 0–2 级物资
    MFColorSlotLoot3,
    MFColorSlotLoot4,
    MFColorSlotLoot5,
    MFColorSlotLoot6,
    MFColorSlotTeam,             // 队伍
    MFColorSlotArmor,            // 头甲
    MFColorSlotSkeleton,         // 真人骨骼
    MFColorSlotBackEnemy,        // 背敌
    MFColorSlotCount
};

#pragma mark - 背敌样式

typedef NS_ENUM(NSInteger, MFBackEnemyStyle) {
    MFBackEnemyStyleCircle = 0,
    MFBackEnemyStyleArrow,
    MFBackEnemyStyleRing,
};

@interface MFSettings : NSObject

+ (instancetype)shared;

#pragma mark 主功能页
@property (nonatomic, assign) BOOL masterEnabled;      // 总开关
@property (nonatomic, assign) BOOL drawEnabled;        // 启用

@property (nonatomic, assign) BOOL showBot;            // 人机显示
/// [M5.150] 队友显示（默认关）：同队且带 PlayerState 的目标
@property (nonatomic, assign) BOOL showTeammates;
@property (nonatomic, assign) BOOL showName;           // 名字
@property (nonatomic, assign) BOOL showArmor;          // 头甲
@property (nonatomic, assign) BOOL showSkeleton;       // 骨骼
@property (nonatomic, assign) BOOL showTracer;         // 射线
@property (nonatomic, assign) BOOL showTeam;           // 队伍
@property (nonatomic, assign) BOOL showHeld;           // 手持
@property (nonatomic, assign) BOOL showDistance;       // 距离
@property (nonatomic, assign) BOOL showHealth;         // 血量
@property (nonatomic, assign) BOOL showRadar;          // 雷达，独立开关

@property (nonatomic, assign) BOOL showLoot;           // 物资
@property (nonatomic, assign) BOOL showBox;            // 盒子
@property (nonatomic, assign) BOOL showLootName;       // 物资名字
@property (nonatomic, assign) BOOL showLootStats;      // 物资统计窗口

@property (nonatomic, assign) NSInteger minLootLevel;  // 物资等级阈值（0=停用）
@property (nonatomic, assign) NSInteger minLootValue;  // 物资价值阈值（0=停用）

@property (nonatomic, assign) float boxDrawDistance;   // 盒子绘制距离（米）
@property (nonatomic, assign) float lootDrawDistance;  // 物资绘制距离（米）
@property (nonatomic, assign) float skeletonDistance;  // 骨骼绘制距离（米）

@property (nonatomic, assign) BOOL backEnemyEnabled;   // 背敌
@property (nonatomic, assign) float backEnemyRadius;   // 背敌半径（px）
/// [M5.179] 背敌距离（米）：超过这个距离的目标不再算"背敌"，避免远处目标也报警
@property (nonatomic, assign) float backEnemyDistance;
@property (nonatomic, assign) MFBackEnemyStyle backEnemyStyle;

#pragma mark 外观页
@property (nonatomic, assign) float fontPerson;        // 人物距离字号
@property (nonatomic, assign) float fontBox;           // 盒子字号
@property (nonatomic, assign) float fontInfo;          // 信息字号
@property (nonatomic, assign) float fontArmor;         // 头甲字号
@property (nonatomic, assign) float skeletonThickness; // 骨骼粗细

#pragma mark 其他页
@property (nonatomic, assign) NSInteger refreshRate;   // 刷新率 60/90/120
@property (nonatomic, assign) NSInteger healthBarStyle;// 血条样式
@property (nonatomic, assign) BOOL smoothAim;          // 平滑度

#pragma mark 模式
@property (nonatomic, assign) BOOL spectatorMode;      // 观战模式
@property (nonatomic, assign) BOOL liveMode;           // 直播模式
/// 默认关闭，便于截图检查 HUD；用户可在菜单中选择开启。
@property (nonatomic, assign) BOOL captureProtectionEnabled;

#pragma mark 自检
/// 渲染自检：不读游戏内存，直接画合成方块。
/// 用途：在偏移校准之前，独立验证 ImGui/Metal/透明层/投影 这条链是否通。
@property (nonatomic, assign) BOOL renderSelfTest;

#pragma mark - 颜色

- (UIColor *)colorForSlot:(MFColorSlot)slot;
- (void)setColor:(UIColor *)color forSlot:(MFColorSlot)slot;

#pragma mark - 持久化

- (BOOL)save;
- (BOOL)load;
- (void)resetToDefaults;

/// 自检：返回当前关键开关注释串，供界面/日志显示
- (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
