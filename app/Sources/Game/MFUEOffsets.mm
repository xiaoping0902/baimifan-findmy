#import "MFUEOffsets.h"

static NSString *const kMFUEProfileKey = @"mf.ue.profile";

@implementation MFUEProfile

- (instancetype)init {
    if ((self = [super init])) {
        _gworldStaticOffset      = kMFUE_DefaultGWorld;
        _world_gameInstance      = kMFUE_World_GameInstance;
        _gameInstance_localPlayers = kMFUE_GameInstance_LocalPlayers;
        _localPlayer_controller  = kMFUE_LocalPlayer_Controller;
        _controller_pawn         = kMFUE_Controller_Pawn;
        _controller_cameraManager = kMFUE_Controller_CameraManager;
        _pawn_playerState        = kMFUE_Pawn_PlayerState;
        _playerState_teamID      = kMFUE_PlayerState_TeamID;
        _world_persistentLevel   = kMFUE_World_PersistentLevel;
        _level_actorsData        = kMFUE_Level_ActorsData;
        _level_actorsNum         = kMFUE_Level_ActorsNum;
        _actor_worldPos          = kMFUE_Actor_WorldPos;
        _cameraManager_cacheEntry = 0;      // 未校准 —— 用扫描自动定
    }
    return self;
}

+ (instancetype)loadFromDefaults {
    MFUEProfile *p = [[MFUEProfile alloc] init];
    NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                       dictionaryForKey:kMFUEProfileKey];
    if ([d isKindOfClass:[NSDictionary class]] && d.count) {
        /* 用 NSNumber 逐项覆盖 —— 缺项保持默认，不因为存盘不完整而丢值 */
        #define MFUE_TAKE_U64(field, key) \
            if (d[key]) p.field = [d[key] unsignedLongLongValue]
        #define MFUE_TAKE_U32(field, key) \
            if (d[key]) p.field = [d[key] unsignedIntValue]

        MFUE_TAKE_U64(gworldStaticOffset, @"gworld");
        MFUE_TAKE_U32(world_gameInstance, @"w_gi");
        MFUE_TAKE_U32(gameInstance_localPlayers, @"gi_lp");
        MFUE_TAKE_U32(localPlayer_controller, @"lp_pc");
        MFUE_TAKE_U32(controller_pawn, @"pc_pawn");
        MFUE_TAKE_U32(controller_cameraManager, @"pc_cam");
        MFUE_TAKE_U32(pawn_playerState, @"pawn_ps");
        MFUE_TAKE_U32(playerState_teamID, @"ps_team");
        MFUE_TAKE_U32(world_persistentLevel, @"w_level");
        MFUE_TAKE_U32(level_actorsData, @"lv_data");
        MFUE_TAKE_U32(level_actorsNum, @"lv_num");
        MFUE_TAKE_U32(actor_worldPos, @"actor_pos");
        MFUE_TAKE_U32(cameraManager_cacheEntry, @"cam_cache");

        #undef MFUE_TAKE_U64
        #undef MFUE_TAKE_U32
    }
    return p;
}

- (void)saveToDefaults {
    NSDictionary *d = @{
        @"gworld":     @(self.gworldStaticOffset),
        @"w_gi":       @(self.world_gameInstance),
        @"gi_lp":      @(self.gameInstance_localPlayers),
        @"lp_pc":      @(self.localPlayer_controller),
        @"pc_pawn":    @(self.controller_pawn),
        @"pc_cam":     @(self.controller_cameraManager),
        @"pawn_ps":    @(self.pawn_playerState),
        @"ps_team":    @(self.playerState_teamID),
        @"w_level":    @(self.world_persistentLevel),
        @"lv_data":    @(self.level_actorsData),
        @"lv_num":     @(self.level_actorsNum),
        @"actor_pos":  @(self.actor_worldPos),
        @"cam_cache":  @(self.cameraManager_cacheEntry),
    };
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kMFUEProfileKey];
}

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<MFUEProfile GWorld=基址+0x%llX 玩家链=%u/%u/%u/%u 相机=%u 敌人=%u/%u/%u 坐标=%u>",
            self.gworldStaticOffset,
            self.world_gameInstance, self.gameInstance_localPlayers,
            self.localPlayer_controller, self.controller_pawn,
            self.controller_cameraManager,
            self.world_persistentLevel, self.level_actorsData,
            self.level_actorsNum, self.actor_worldPos];
}

@end
