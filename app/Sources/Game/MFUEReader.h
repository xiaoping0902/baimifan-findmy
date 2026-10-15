//
//  MFUEReader.h — UE4 对象图读取器
//
//  和 MFGameReader 的区别：
//    MFGameReader —— 走「白米饭的那条链」（纯偏移链，起点是 3 个手填基址）
//    MFUEReader   —— 走「UE4 标准对象图」（起点是模块基址 + GWorld 静态偏移）
//
//  两条路并存：UE4 路只需要一个模块基址（模块定位能自动拿到），
//  所以它是【可自动建立】的那条；白米饭那条需要一个未知的根地址。
//
#import <Foundation/Foundation.h>
#import "MFUEOffsets.h"
#import "MFGameReader.h"
#include "MFProjection.h"

NS_ASSUME_NONNULL_BEGIN

/// UE4 链的解析结果（每一步都留痕，便于诊断哪一环断了）
@interface MFUEResolveResult : NSObject
@property (nonatomic, assign) uint64_t libBase;          // 模块基址
@property (nonatomic, assign) uint64_t gworld;           // GWorld
@property (nonatomic, assign) uint64_t gameInstance;     // UWorld::OwningGameInstance
@property (nonatomic, assign) uint64_t localPlayers;     // UGameInstance::LocalPlayers
@property (nonatomic, assign) uint64_t localPlayer;      // ULocalPlayer*
@property (nonatomic, assign) uint64_t playerController; // APlayerController*
@property (nonatomic, assign) uint64_t pawn;             // AcknowledgedPawn
@property (nonatomic, assign) uint64_t cameraManager;    // PlayerCameraManager
@property (nonatomic, assign) uint64_t playerState;      // Pawn::PlayerState
@property (nonatomic, assign) int      teamID;           // 阵营/队伍 ID
@property (nonatomic, assign) uint64_t level;            // UWorld::PersistentLevel
@property (nonatomic, assign) uint64_t actorsData;       // ULevel::Actors.Data
@property (nonatomic, assign) int      actorsNum;        // ULevel::Actors.Num

/// 断在哪一步（空 = 全通）
@property (nonatomic, copy, nullable) NSString *brokenAt;
@property (nonatomic, strong) NSMutableArray<NSString *> *trace;   // 逐级日志
@end

@interface MFUEReader : NSObject

+ (instancetype)shared;

/// 运行时可改偏移
@property (nonatomic, strong) MFUEProfile *profile;

/// 模块基址（由 MFModuleLocator 设进来）
@property (nonatomic, assign) uint64_t libBase;

#pragma mark - 链解析

/// 从 libBase 一路解到 Actors 数组。每一步都有 trace。
- (MFUEResolveResult *)resolve;

#pragma mark - 相机

/// 读相机 POV。
/// profile.cameraManager_cacheEntry == 0 时先自动扫描（见 scanCameraCacheOffset）。
- (BOOL)readCamera:(MFCamera *)out result:(MFUEResolveResult *)r;

/// 在 CameraManager 对象里扫「CameraCacheEntry」的偏移。
/// 判据是 FMinimalViewInfo 的布局特征（见 MFUEOffsets.h），
/// 所以这是【自验证】的 —— 扫到的必须是合理的坐标+角度+FOV。
/// 返回 0 表示没扫到。
- (uint32_t)scanCameraCacheOffset:(uint64_t)cameraManager
                           report:(NSMutableString *_Nullable)rep;

#pragma mark - 敌人

/// 枚举 ULevel 里的全部 Actor（只返回坐标可读的那些）。
- (NSArray<MFEntity *> *)enumerateActors:(MFUEResolveResult *)r
                                  camera:(MFCamera)camera
                                  screen:(MFScreen)screen;

#pragma mark - 诊断

/// 上一次解析的完整报告
+ (NSString *)lastReport;
- (NSString *)diagnosticReport;

@end

NS_ASSUME_NONNULL_END
