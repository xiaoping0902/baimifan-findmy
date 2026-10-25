#pragma once
// Included inside namespace ios; all coordinates are logical panel pixels.
static bool DrawingValue(const UIState& st,int index) {
    switch(index){
        case kStandaloneHorseDrawingItem:return st.horseEnabled;
        case kStandaloneOffscreenDistanceItem:return st.offscreenDistanceEnabled;
        case kStandaloneWeaponIconItem:return st.weaponIconEnabled;
        case kStandaloneVehicleIconItem:return st.vehicleIconEnabled;
        case kStandaloneRadarDrawingItem:return st.radarEnabled;
        default:return st.feat[index];
    }
}
static void SetDrawingValue(UIState& st,int index,bool value) {
    switch(index){
        case kStandaloneHorseDrawingItem:st.horseEnabled=value;break;
        case kStandaloneOffscreenDistanceItem:st.offscreenDistanceEnabled=value;break;
        case kStandaloneWeaponIconItem:st.weaponIconEnabled=value;break;
        case kStandaloneVehicleIconItem:st.vehicleIconEnabled=value;break;
        case kStandaloneRadarDrawingItem:st.radarEnabled=value;break;
        default:st.feat[index]=value;break;
    }
    st.configDirty=true;
}
static float Home(Canvas& c) {
    const float gap=12,w=(c.width-30)/4;
    char fps[24],features[24],loot[24];
    snprintf(fps,sizeof(fps),"%.0f FPS",std::isfinite(c.st.renderFps)?c.st.renderFps:0.0f);
    snprintf(features,sizeof(features),"%d / %d",CountEnabledDrawing(c.st),kVisibleDrawingItemCount);
    snprintf(loot,sizeof(loot),"%d / %d",CountEnabledConfigurableLoot(c.st),kVisibleLootItemCount);
    c.metric(0,0,w,"实时帧率",fps,c.tc.accent);
    c.metric(w+10,0,w,"绘制项目",features,c.tc.success);
    c.metric((w+10)*2,0,w,"物资项目",loot,c.tc.warning);
    c.metric((w+10)*3,0,w,"配置",c.st.configDirty?"待同步":"已同步",c.st.configDirty?c.tc.warning:c.tc.success);
    const bool two=c.width>=600;
    const float cw=two?(c.width-gap)/2:c.width;
    c.card(0,90,cw,242,"运行状态");
    c.info(14,128,cw-28,"界面",c.st.expanded?"已展开":"已收起",c.tc.success);
    c.info(14,161,cw-28,"性能策略",HasActiveOverlay(c.st)?"绘制同步":"空闲降帧",c.tc.accent);
    c.info(14,194,cw-28,"自瞄",c.st.aim.enabled?"已开启":"已关闭",c.st.aim.enabled?c.tc.success:c.tc.textMuted);
    c.info(14,227,cw-28,"追踪",c.st.aim.trackingEnabled?"已开启":"已关闭",c.st.aim.trackingEnabled?c.tc.success:c.tc.textMuted);
    c.info(14,260,cw-28,"配置",c.st.configDirty?"待同步":"已同步",c.st.configDirty?c.tc.warning:c.tc.textMuted);
    // 「数据读取」自查行（2026-09-22 用户报"什么都没画"）：
    //   相机✗ → 读不到相机；状态≠2(GameLinked) → 还没进对局/没挂上；
    //   玩家/物资/载具 都是 0 → 列表空，说明扫描没跑或读失败。
    char diag[160];
    snprintf(diag,sizeof(diag),"相机%s 状态%d 玩家%d 物资%d 载具%d",
             c.st.cameraValid?"正常":"断开",c.st.gameStateId,
             c.st.realCount+c.st.botCount,c.st.lootCount,c.st.vehicleCount);
    c.info(14,293,cw-28,"数据读取",diag,c.st.cameraValid?c.tc.success:c.tc.danger);
    // 「模型显示」自查行(2026-09-22)：卡在哪一步一眼看出 ——
    //   PhysX未就绪 → 场景还没建好(等几秒); 命中网格=0 → 准心射线没打中/朝向不对;
    //   命中网格>0 但画出=0 → 顶点投影失败(Transform 或坐标问题)。
    // ★ 性能面板(2026-09-23): 每秒快照的各阶段耗时(ms/帧) —— 一眼看出时间花在哪
    {
        char pdiag[192];
        snprintf(pdiag,sizeof(pdiag),"帧%.1fms 玩家%d 世界%d 渲染%d 瞄准%d 贴图%d",
                 c.st.perfFps>0?1000.0f/c.st.perfFps:0.0f,
                 c.st.perfPlayersMs,c.st.perfWorldMs,c.st.perfRenderMs,
                 c.st.perfAimMs,c.st.perfTextureMs);
        c.info(14,392,cw-28,"性能",pdiag,
               (c.st.perfPlayersMs+c.st.perfWorldMs)<8?c.tc.success:c.tc.warning);
    }
    // 活动密钥自查(2026-09-23): 扫到几个/进列表几个 —— "密钥不显示"一看就知道卡在哪
    if (c.st.keyTraceSeen > 0 || c.st.keyTraceAdded > 0) {
        char kdiag[128];
        snprintf(kdiag,sizeof(kdiag),"扫到%d个 进列表%d个",c.st.keyTraceSeen,c.st.keyTraceAdded);
        c.info(14,326,cw-28,"活动密钥",kdiag,c.st.keyTraceAdded>0?c.tc.success:c.tc.warning);
    }
    if (c.st.aimModelEnabled) {
        char mdiag[192];
        snprintf(mdiag,sizeof(mdiag),"PhysX%s 网格%d 画出%d 顶点%.0f,%.0f,%.0f",
                 c.st.physxReady?"就绪":"未就绪",c.st.modelMeshTris,c.st.modelTrisDrawn,
                 c.st.modelV0X,c.st.modelV0Y,c.st.modelV0Z);
        c.info(14,359,cw-28,"模型显示",mdiag,c.st.modelTrisDrawn>0?c.tc.success:c.tc.warning);
    }
    float x=two?cw+gap:0,y=two?90:344;
    c.card(x,y,cw,242,"面板控制");
    const char* options[]={"60","90","120","144"};
    const int values[]={60,90,120,144};
    int index=0;for(int i=0;i<4;i++)if(c.st.fpsSel==values[i])index=i;
    if(c.segment(x+14,y+38,cw-28,"绘制帧率",options,4,index,"home_fps"))c.st.fpsSel=values[index];
    c.slider(x+14,y+83,cw-28,"面板大小",c.st.uiScale,kPanelScaleMinimum,kPanelScaleMaximum,"%.0f%%",100*kPanelDefaultWidthRatio,"panel_size",.01f/kPanelDefaultWidthRatio);
    c.toggle(x+14,y+130,cw-28,"过录屏",c.st.excludeFromRecording,"exclude_recording");
    c.info(x+14,y+178,cw-140,"配置管理","",c.tc.textMuted);
    if(c.button(x+cw-112,y+182,98,"重置配置","reset_config",true))c.st.resetConfigRequested=true;
    return y+242;
}
static float Selection(Canvas& c,bool drawing) {
    static const char* drawingNames[]={"真人","人机","骨骼","射线","血量","名字","队伍","手持","背敌","距离","载具","手持贴图","载具贴图","头甲包","人物状态","只绘制马","背敌距离","爆炸范围","烟雾时间","绘制雷达"};
    static_assert(IM_ARRAYSIZE(drawingNames)==kVisibleDrawingItemCount,"drawing labels must match indices");
    static const char* lootNames[]={"爆炸猎弓","子弹/箭矢","三级套","金插","医疗箱","急救包","止痛药","肾上腺素","能量饮料","投掷物","宝箱","人物盒子","军事宝箱","保险箱","超级物资箱","海盗福利箱","空投"};
    const float gap=10,cw=(c.width-3*gap)/4;
    auto drawTile=[&](int i,float y,int column){
        char id[32];snprintf(id,sizeof(id),"%s_%d",drawing?"drawing":"loot",i);
        int index=drawing?kVisibleDrawingFeatureIndices[i]:(i<kConfigurableLootItemCount?kConfigurableLootCategoryIndices[i]:DrawingAirDrop);
        bool value=drawing?DrawingValue(c.st,index):(i<kConfigurableLootItemCount?c.st.grid[index]==1:c.st.feat[DrawingAirDrop]);
        if(c.tile(column*(cw+gap),y,cw,drawing?drawingNames[i]:lootNames[i],value,id)){
            if(drawing)SetDrawingValue(c.st,index,!value);
            else if(i==kConfigurableLootItemCount)c.st.feat[DrawingAirDrop]=!value;
            else c.st.grid[index]=value?0:1;
        }
    };
    if(drawing){
        c.section(2,0,"基础绘制");
        for(int i=0;i<11;i++)drawTile(i,25+(i/4)*58,i%4);
        c.section(2,211,"个性绘制");
        for(int i=11;i<kVisibleDrawingItemCount;i++)drawTile(i,236+((i-11)/4)*58,(i-11)%4);
        const float extraY = 236.0f + ((kVisibleDrawingItemCount-11+3)/4)*58.0f + 12;
        if(c.st.radarEnabled){
            const float cardHeight=212.0f;
            c.card(0,extraY,c.width,cardHeight,"雷达设置");
            c.slider(14,extraY+38,c.width-28,"左右位置",c.st.radarXRatio,0,1,"%.0f%%",100,"radar_x");
            c.slider(14,extraY+78,c.width-28,"上下位置",c.st.radarYRatio,0,1,"%.0f%%",100,"radar_y");
            c.slider(14,extraY+118,c.width-28,"雷达大小",c.st.radarRadiusRatio,.08f,.25f,"%.0f%%",100,"radar_size");
            c.slider(14,extraY+158,c.width-28,"雷达范围",c.st.radarRangeM,50,1000,"%.0f米",1,"radar_range");
            return extraY+cardHeight;
        }
        return extraY;
    }
    for(int i=0;i<17;i++)drawTile(i,(i/4)*58,i%4);
    // 飞索(钩锁)/武器箱/药箱: 不占 LootCategory 格子(加了会让配置 grid[] 中段变长,
    // 后面所有字段位移), 各自独立开关, 默认打开。第 5 行正好排满 4 格。
    if(c.tile(cw+gap,4*58,cw,"飞索",c.st.ziplineEnabled,"loot_zipline")){
        c.st.ziplineEnabled=!c.st.ziplineEnabled; c.st.configDirty=true;
    }
    if(c.tile((cw+gap)*2,4*58,cw,"武器箱",c.st.weaponBoxEnabled,"loot_weapon_box")){
        c.st.weaponBoxEnabled=!c.st.weaponBoxEnabled; c.st.configDirty=true;
    }
    if(c.tile((cw+gap)*3,4*58,cw,"药箱",c.st.medicalBoxEnabled,"loot_medical_box")){
        c.st.medicalBoxEnabled=!c.st.medicalBoxEnabled; c.st.configDirty=true;
    }
    // 通用箱子(BoxType 识别: 保险箱/储物柜/文件柜/工具箱/木箱/垃圾桶…18 种)
    if(c.tile(0,5*58,cw,"箱子",c.st.containerEnabled,"loot_container")){
        c.st.containerEnabled=!c.st.containerEnabled; c.st.configDirty=true;
    }
    return 348;
}
static float Aim(Canvas& c) {
    const bool two=c.width>=600;const float gap=12,cw=two?(c.width-gap)/2:c.width;
    // ⚠️ 卡片高度必须容得下最后一行：最后一行 segment 在 y=290、行高 36 → 底部 326，
    //    再加 12 的下边距 = 338。
    //    原来是 302（最后一行在 254 时正好），今天加「拟人化拉枪」那一行时漏改，
    //    导致它被挤出卡片、压在面板底边上（真机可见）。
    c.card(0,0,cw,338,"基础瞄准");
    c.toggle(14,38,cw-28,"自瞄总开关",c.st.aim.enabled,"aim_enabled");
    bool ignoreBots=c.st.aim.target==AimTargetMode::Human;
    if(c.toggle(14,74,cw-28,"人机不锁",ignoreBots,"aim_bots"))c.st.aim.target=ignoreBots?AimTargetMode::Human:AimTargetMode::All;
    c.toggle(14,110,cw-28,"倒地不锁",c.st.aim.ignoreDowned,"aim_downed");
    c.toggle(14,146,cw-28,"自瞄圈",c.st.aim.drawFov,"aim_fov_on");
    const char* triggerLabels[]={"开火","开镜","开火/开镜"};
    int trigger=c.st.aim.trigger==AimTriggerMode::Ads?1:c.st.aim.trigger==AimTriggerMode::FireOrAds?2:0;
    if(c.segment(14,182,cw-28,"锁定触发",triggerLabels,3,trigger,"aim_trigger"))c.st.aim.trigger=trigger==1?AimTriggerMode::Ads:trigger==2?AimTriggerMode::FireOrAds:AimTriggerMode::Fire;
    const char* pointLabels[]={"头部","胸部","动态"};int point=ImClamp(int(c.st.aim.point),0,2);
    if(c.segment(14,218,cw-28,"瞄准部位",pointLabels,3,point,"aim_point"))c.st.aim.point=(AimPointMode)point;
    const char* enabledLabels[]={"关闭","开启"};int stable=c.st.aim.stableLock?1:0;
    if(c.segment(14,254,cw-28,"稳定锁点",enabledLabels,2,stable,"aim_stable"))c.st.aim.stableLock=stable==1;
    // G15 拟人化：扰动拉枪速率波形（呼吸/微颤/逐发衰减/过冲回修），
    // 用于破坏反作弊的"角速度方差过小、帧间切线偏差过小、同方向重复"三项统计。
    int human=c.st.aim.humanize?1:0;
    if(c.segment(14,290,cw-28,"拟人化拉枪",enabledLabels,2,human,"aim_humanize"))c.st.aim.humanize=human==1;
    // 窄屏单列：基础瞄准(338) + 12 间距 = 350；宽屏右列「锁定参数」也从 0 开始
    float x=two?cw+gap:0,y=two?0:350;
    c.card(x,y,cw,330,"锁定参数");
    c.slider(x+14,y+38,cw-28,"自瞄圈",c.st.aim.fovScale,.05f,.35f,"%.0f%%",100,"aim_circle");
    c.slider(x+14,y+78,cw-28,"开镜自瞄距离",c.st.aim.maxDistanceM,50,500,"%.0f米",1,"aim_distance");
    c.slider(x+14,y+118,cw-28,"锁定速度",c.st.aim.lockSpeed,.5f,kAimLockSpeedMaximum,"%.0f%%",100,"aim_lock");
    c.slider(x+14,y+158,cw-28,"近点制动",c.st.aim.nearDamping,.3f,1,"%.0f%%",100,"aim_near");
    c.slider(x+14,y+198,cw-28,"压枪力度",c.st.aim.recoilStrength,0,kAimRecoilStrengthMaximum,"%.0f%%",100,"aim_recoil");
    c.slider(x+14,y+238,cw-28,"移动预判",c.st.aim.prediction,0,1,"%.0f%%",100,"aim_prediction");
    c.slider(x+14,y+278,cw-28,"不开镜自瞄距离",c.st.aim.hipAimMaxDistanceM,0,300,"%.0f米",1,"aim_hip_distance");
    // 宽屏：左列 338 结束 → 338+12 = 350（原来写 354 是按 302 的旧高度算的）
    // 窄屏：基础瞄准 338 + 12 → 锁定参数 350，高 330 → 结束 680，+12 = 692
    y=two?350:692;
    c.card(0,y,c.width,370,"拉枪速度（自瞄）");
    c.slider(14,y+38,c.width-28,"全局速度",c.st.aim.gyroStrength,0,kAimStrengthMaximum,"%.0f%%",100,"aim_gyro");
    const char* labels[]={"不开镜","红点","二倍镜","三倍镜","四倍镜","六倍镜","八倍镜"};
    float* values[]={&c.st.aim.gyroHipSensitivity,&c.st.aim.gyroReflexSensitivity,&c.st.aim.gyro2xSensitivity,&c.st.aim.gyro3xSensitivity,&c.st.aim.gyro4xSensitivity,&c.st.aim.gyro6xSensitivity,&c.st.aim.gyro8xSensitivity};
    for(int i=0;i<7;i++){char id[32];snprintf(id,sizeof(id),"aim_scope_%d",i);c.slider(14,y+78+40*i,c.width-28,labels[i],*values[i],0,kAimScopeSensitivityMaximum,"%.0f%%",100,id);}
    y+=370;
    c.card(0,y,c.width,370,"倍镜压枪力度（压枪专用）");
    for(int i=0;i<7;i++){char id[32];snprintf(id,sizeof(id),"aim_recoil_scope_%d",i);c.slider(14,y+38+40*i,c.width-28,labels[i],c.st.aim.recoilScopeScale[i],0,kAimScopeSensitivityMaximum,"%.0f%%",100,id);}
    return y+370;
}
static float Tracking(Canvas& c) {
    const bool two=c.width>=600;const float gap=12,cw=two?(c.width-gap)/2:c.width;
    c.card(0,0,cw,302,"追踪开关");
    c.toggle(14,38,cw-28,"追踪总开关",c.st.aim.trackingEnabled,"track_enabled");
    c.toggle(14,74,cw-28,"单发枪追踪",c.st.aim.singleShotTracking,"track_single");
    c.toggle(14,110,cw-28,"爆炸猎弓追踪",c.st.aim.explosiveBowTracking,"track_bow");
    c.toggle(14,146,cw-28,"步枪追踪",c.st.aim.rifleTracking,"track_rifle");
    c.toggle(14,182,cw-28,"人机不追",c.st.aim.trackingIgnoreBots,"track_ignore_bots");
    c.slider(14,218,cw-28,"不开镜追踪距离",c.st.aim.hipTrackMaxDistanceM,0,300,"%.0f米",1,"track_hip_distance");
    c.text(14,270,10,c.tc.textFaint,"狙击 / 射手步枪使用单发参数");
    const bool single=c.st.aim.singleShotTracking||c.st.aim.explosiveBowTracking;
    float x=two?cw+gap:0,y=two?0:314;
    float h=50+(single?160:0)+(c.st.aim.rifleTracking?160:0);
    h=ImMax(h,90.0f);
    c.card(x,y,cw,h,"追踪参数");float row=y+38;
    const char* pointLabels[]={"头","胸","随机"};
    if(single){
        c.slider(x+14,row,cw-28,"单发概率",c.st.aim.singleShotTrackingProbability,0,1,"%.0f%%",100,"single_probability");row+=40;
        c.slider(x+14,row,cw-28,"单发距离",c.st.aim.singleShotTrackingDistanceM,20,500,"%.0f米",1,"single_distance");row+=40;
        c.slider(x+14,row,cw-28,"单发范围",c.st.aim.singleShotTrackingFovScale,.03f,.35f,"%.0f%%",100,"single_range");row+=40;
        int point=ImClamp((int)c.st.aim.singleShotTrackingPoint,0,2);
        if(c.segment(x+14,row,cw-28,"单发部位",pointLabels,3,point,"single_track_point"))
            c.st.aim.singleShotTrackingPoint=(AimTrackingPointMode)point;
        row+=40;
    }
    if(c.st.aim.rifleTracking){
        c.slider(x+14,row,cw-28,"步枪概率",c.st.aim.rifleTrackingProbability,0,1,"%.0f%%",100,"rifle_probability");row+=40;
        c.slider(x+14,row,cw-28,"步枪距离",c.st.aim.rifleTrackingDistanceM,20,500,"%.0f米",1,"rifle_distance");row+=40;
        c.slider(x+14,row,cw-28,"步枪范围",c.st.aim.rifleTrackingFovScale,.03f,.35f,"%.0f%%",100,"rifle_range");row+=40;
        int point=ImClamp((int)c.st.aim.rifleTrackingPoint,0,2);
        if(c.segment(x+14,row,cw-28,"步枪部位",pointLabels,3,point,"rifle_track_point"))
            c.st.aim.rifleTrackingPoint=(AimTrackingPointMode)point;
        row+=40;
    }
    if(!single&&!c.st.aim.rifleTracking)c.text(x+14,row,11,c.tc.textMuted,"先开启一种追踪类型");
    y=two?ImMax(302.0f,h)+12:y+h+12;
    return y;
}
static float Personality(Canvas& c) {
    const bool two=c.width>=600;const float cw=two?(c.width-12)/2:c.width;
    // 卡片高度 470 -> 478：末尾只加了一行「骨骼线条粗细」。
    // 该行在 y=430、行高 36 => 底 466，再留 12 边距 = 478。
    c.card(0,0,cw,478,"外观与绘制大小");
    const char* themes[]={"纯白","雾蓝","浅紫","柔粉"};
    if(c.segment(14,38,cw-28,"主题",themes,4,c.st.theme,"theme")){
        const float hues[]={.587f,.587f,.72f,.96f};c.st.accentHue=hues[c.st.theme];
    }
    c.text(14,85,12,c.tc.text,"强调色");
    const float hues[]={.587f,.55f,.72f,.96f,.35f,.10f};
    const float start=cw-14-6*28;
    for(int i=0;i<6;i++){
        char id[24];snprintf(id,sizeof(id),"accent_%d",i);
        ImU32 col=GetTheme(c.st.theme,1,hues[i]).accent;
        if(c.swatch(start+i*28,83,col,std::fabs(c.st.accentHue-hues[i])<.012f,id)){c.st.accentHue=hues[i];c.st.configDirty=true;}
    }
    const char* styles[]={"分段","胶囊"};int style=NormalizeHealthBarStyleId(c.st.healthBarStyle)==kHealthBarStyleCapsule?1:0;
    if(c.segment(14,110,cw-28,"血条样式",styles,2,style,"health_style"))c.st.healthBarStyle=style?kHealthBarStyleCapsule:kHealthBarStyleSegmented;
    c.slider(14,150,cw-28,"背景透明度",c.st.bgAlpha,.6f,1,"%.0f%%",100,"background_alpha");
    c.slider(14,190,cw-28,"灵动岛位置",c.st.islandYOffset,-24,180,"%.0f",1,"island_y");
    c.slider(14,230,cw-28,"灵动岛透明度",c.st.islandAlpha,.2f,1,"%.0f%%",100,"island_alpha");
    c.slider(14,270,cw-28,"绘制字体大小",c.st.espFontScale,.50f,1.20f,"%.0f%%",100,"esp_font_scale");
    c.slider(14,310,cw-28,"物资字体大小",c.st.lootFontScale,.70f,1.20f,"%.0f%%",100,"loot_font_scale");
    c.slider(14,350,cw-28,"载具文字/血条",c.st.vehicleFontScale,.70f,1.40f,"%.0f%%",100,"vehicle_font_scale");
    c.slider(14,390,cw-28,"载具贴图大小",c.st.vehicleIconScale,.50f,1.50f,"%.0f%%",100,"vehicle_icon_scale");
    // 骨骼线条粗细（2026-09-15 用户要求）。
    // 开关不放在这里 —— 「绘制」页里已经有「骨骼」开关了，两处重复没意义。
    // 这里只管**粗细**，倍率 1.00 = 原始宽度（1.9~4.5px，随人物在屏幕上的身高变化）。
    c.slider(14,430,cw-28,"骨骼线条粗细",c.st.boneLineWidth,.50f,3.00f,"%.0f%%",100,"personality_bone_width");
    float x=two?cw+12:0,y=two?0:490;
    c.card(x,y,cw,340,"自定义颜色");
    const char* labels[]={"真人骨骼","人机骨骼","掩体变色","能量饮料","止痛药","肾上腺素","医疗箱"};
    ImVec4* values[]={&c.st.humanSkeletonColor,&c.st.botSkeletonColor,&c.st.coverColor,&c.st.energyDrinkColor,&c.st.painkillerColor,&c.st.adrenalineColor,&c.st.medKitColor};
    for(int i=0;i<7;i++){char id[24];snprintf(id,sizeof(id),"color_%d",i);c.color(x+14,y+38+i*36,cw-28,labels[i],*values[i],id);}
    return two ? ImMax(478.0f, y + 340.0f) : y + 340.0f;
}
static float Settings(Canvas& c) {
    c.card(0,0,c.width,268,"运行选项");
    c.toggle(14,38,c.width-28,"开发者模式 · 准心对准物资显示类名",c.st.developerMode,"developer_mode");
    c.toggle(14,74,c.width-28,c.st.decryptReady?"解密逻辑 · 算法自检通过":"解密逻辑 · 等待就绪",c.st.decryptEnabled,"decrypt_enabled");
    c.toggle(14,110,c.width-28,c.st.petFilterEnabled?"宠物过滤 · 仅真人 / 人机":"宠物过滤 · 包含宠物",c.st.petFilterEnabled,"pet_filter");
    c.toggle(14,146,c.width-28,"背景图",c.st.backgroundSlideshowEnabled,"background_slideshow");
    // 模型显示(2026-09-22): 准心对准的物体画出它的三角网格线框(物体级, 无距离限制)
    // 数据源和"掩体变色"同一套 PhysX 场景, 与巴巴托斯"绘制Physx"同源。
    c.toggle(14,182,c.width-28,c.st.aimModelEnabled?"模型显示 · 准心对准的物体":"模型显示 · 已关闭",c.st.aimModelEnabled,"aim_model");
    c.card(0,238,c.width,60,nullptr);
    c.text(14,258,12,c.tc.textMuted,"结束悬浮窗运行");
    if(c.button(c.width-112,251,98,"退出程序","exit_program",true))c.st.wantExit=true;
    return 272;
}
static float DrawPage(Canvas& c,int tab) {
    switch(tab){
        case 0:return Home(c);
        case 1:return Selection(c,true);
        case 2:return Aim(c);
        case 3:return Tracking(c);
        case 4:return Selection(c,false);
        case 5:return Personality(c);
        default:return Settings(c);
    }
}
