#pragma once
// Included inside namespace ios; coordinates are logical panel pixels.
static float Home(Canvas& c) {
    c.card(0,0,c.width,142,"运行状态");
    c.info(14,35,c.width-28,"数据",c.st.cameraValid?"已连接":"等待连接",c.st.cameraValid?c.tc.success:c.tc.textMuted);
    char people[48],loot[32];
    snprintf(people,sizeof(people),"真人 %d / 人机 %d",c.st.realCount,c.st.botCount);
    snprintf(loot,sizeof(loot),"%d 件",c.st.lootCount);
    c.info(14,69,c.width-28,"人物",people,c.tc.text);
    c.info(14,103,c.width-28,"物资",loot,c.tc.text);
    c.card(0,154,c.width,212,"面板控制");
    c.toggle(14,190,c.width-28,"绘制总开关",c.st.feat[DrawingHuman],"drawing_master");
    c.slider(14,232,c.width-28,"面板大小",c.st.uiScale,kPanelScaleMinimum,kPanelScaleMaximum,"%.0f%%",100*kPanelDefaultWidthRatio,"panel_size",.01f/kPanelDefaultWidthRatio);
    c.toggle(14,274,c.width-28,"实时帧率",c.st.fpsEnabled,"fps_enabled");
    c.text(14,328,13,c.tc.textMuted,"拖动标题移动，右下角缩放");
    return 366;
}
static float Drawing(Canvas& c) {
    static const char* names[]={"骨骼","射线","血条","名字","队伍","手持","背敌","距离","头甲包"};
    static const int indices[]={DrawingSkeleton,DrawingRay,DrawingHealth,DrawingName,DrawingTeam,DrawingWeapon,DrawingOffscreen,DrawingDistance,DrawingEquipment};
    const float cell=(c.width-28-18)/4;
    c.card(0,0,c.width,224,"真人信息");
    for(int i=0;i<IM_ARRAYSIZE(indices);++i){
        char id[32];snprintf(id,sizeof(id),"drawing_%d",indices[i]);
        c.tile(14+(i%4)*(cell+6),34+(i/4)*62,cell,names[i],c.st.feat[indices[i]],id);
    }
    c.card(0,236,c.width,162,"人机信息");
    c.tile(14,270,cell,"人机\n显示",c.st.feat[DrawingBot],"drawing_1");
    c.tile(14+(cell+6),270,cell,"名字",c.st.botNameEnabled,"bot_name");
    c.tile(14+2*(cell+6),270,cell,"骨骼",c.st.botSkeletonEnabled,"bot_skeleton");
    c.tile(14+3*(cell+6),270,cell,"血条",c.st.botHealthEnabled,"bot_health");
    c.tile(14,332,cell,"射线",c.st.botTracerEnabled,"bot_tracer");
    c.tile(14+(cell+6),332,cell,"头甲包",c.st.botArmorEnabled,"bot_armor");
    c.card(0,410,c.width,130,"显示范围");
    c.slider(14,446,c.width-28,"骨骼距离",c.st.skeletonDistance,20,500,"%.0fm",1,"skeleton_distance",10);
    c.slider(14,488,c.width-28,"背敌距离",c.st.backEnemyDistance,20,500,"%.0fm",1,"back_enemy_distance",10);
    return 540;
}
static float Radar(Canvas& c) {
    c.card(0,0,c.width,82,"雷达显示");
    c.toggle(14,34,c.width-28,"雷达开关",c.st.radarEnabled,"radar_enabled");
    c.card(0,94,c.width,234,"位置与大小");
    c.slider(14,130,c.width-28,"水平位置",c.st.radarXRatio,0,1,"%.0f%%",100,"radar_x",.01f);
    c.slider(14,172,c.width-28,"垂直位置",c.st.radarYRatio,0,1,"%.0f%%",100,"radar_y",.01f);
    c.slider(14,214,c.width-28,"雷达大小",c.st.radarRadiusRatio,.08f,.25f,"%.0f%%",100,"radar_size",.01f);
    if(c.button(14,270,c.width-28,"恢复默认位置","radar_reset")){
        c.st.radarXRatio=.125f;c.st.radarYRatio=400.0f/1080.0f;
        c.st.radarRadiusRatio=150.0f/1080.0f;c.st.configDirty=true;
    }
    return 328;
}
static float Loot(Canvas& c) {
    const float toggleCell=(c.width-28-18)/4;
    c.card(0,0,c.width,100,"物资显示");
    c.tile(14,34,toggleCell,"物资\n标记",c.st.lootEnabled,"loot_enabled");
    c.tile(14+toggleCell+6,34,toggleCell,"物资\n名字",c.st.lootNamesEnabled,"loot_names");
    c.tile(14+2*(toggleCell+6),34,toggleCell,"盒子\n标记",c.st.boxesEnabled,"loot_boxes");
    c.tile(14+3*(toggleCell+6),34,toggleCell,"物资\n统计",c.st.lootStatsEnabled,"loot_stats");
    c.card(0,112,c.width,122,"六档品质");
    const char* grades[]={"1 白","2 绿","3 蓝","4 紫","5 金","6 红"};
    const ImU32 colors[]={IM_COL32(255,255,255,255),IM_COL32(40,255,85,255),
        IM_COL32(51,140,255,255),IM_COL32(179,77,255,255),IM_COL32(255,204,0,255),IM_COL32(255,41,41,255)};
    const float cell=(c.width-40)/3;
    for(int i=0;i<6;++i){
        const float x=14+(i%3)*(cell+6),y=148+(i/3)*36;
        c.rect(x,y,cell,29,IM_COL32(26,32,43,245),8);
        c.text(x+9,y+7,13,colors[i],grades[i]);
    }
    c.card(0,246,c.width,228,"筛选与距离");
    c.slider(14,282,c.width-28,"最低品质",c.st.minLootLevel,0,6,"%.0f",1,"loot_level",1);
    c.slider(14,324,c.width-28,"最低价值",c.st.minLootValue,0,200000,"%.0f",1,"loot_value",1000);
    c.slider(14,366,c.width-28,"物资距离",c.st.lootDistance,20,500,"%.0fm",1,"loot_distance",10);
    c.slider(14,408,c.width-28,"盒子距离",c.st.boxDistance,20,500,"%.0fm",1,"box_distance",10);
    c.text(14,450,12,c.tc.textMuted,"品质和价值设为 0 时显示全部");
    c.card(0,486,c.width,178,"统计窗口位置");
    c.slider(14,522,c.width-28,"水平位置",c.st.lootStatsXRatio,0,1,"%.0f%%",100,"loot_stats_x",.01f);
    c.slider(14,564,c.width-28,"垂直位置",c.st.lootStatsYRatio,0,1,"%.0f%%",100,"loot_stats_y",.01f);
    if(c.button(14,614,c.width-28,"恢复默认位置","loot_stats_reset")){
        c.st.lootStatsXRatio=.01f;c.st.lootStatsYRatio=.18f;c.st.configDirty=true;
    }
    return 664;
}
static float Personality(Canvas& c) {
    c.card(0,0,c.width,394,"界面与字号");
    const char* themes[]={"纯白","雾蓝","浅紫","柔粉"};
    if(c.segment(14,36,c.width-28,"主题",themes,4,c.st.theme,"theme")){
        const float hues[]={.587f,.587f,.72f,.96f};c.st.accentHue=hues[c.st.theme];
    }
    c.slider(14,80,c.width-28,"不透明度",c.st.bgAlpha,.85f,1,"%.0f%%",100,"background_alpha");
    c.slider(14,122,c.width-28,"面板大小",c.st.uiScale,kPanelScaleMinimum,kPanelScaleMaximum,"%.0f%%",100*kPanelDefaultWidthRatio,"panel_size",.01f/kPanelDefaultWidthRatio);
    c.slider(14,164,c.width-28,"人物字号",c.st.espFontScale,.85f,1.5f,"%.0f%%",100,"esp_font_scale");
    c.slider(14,206,c.width-28,"物资字号",c.st.lootFontScale,.85f,1.5f,"%.0f%%",100,"loot_font_scale");
    c.slider(14,248,c.width-28,"骨骼粗细",c.st.boneLineWidth,.5f,3,"%.1f",1,"personality_bone_width");
    const char* styles[]={"细线","胶囊","分段"};
    int style=ImClamp(c.st.healthBarStyle,0,2);
    if(c.segment(14,294,c.width-28,"血条样式",styles,3,style,"health_style"))c.st.healthBarStyle=style;
    c.text(14,346,12,c.tc.textMuted,"灵动岛位于屏幕顶部中央");
    c.card(0,406,c.width,126,"绘制颜色");
    c.color(14,442,c.width-28,"真人骨骼",c.st.humanSkeletonColor,"human_skeleton_color");
    c.color(14,482,c.width-28,"人机骨骼",c.st.botSkeletonColor,"bot_skeleton_color");
    return 532;
}
static float DrawPage(Canvas& c,int tab) {
    switch(tab){
        case 0:return Home(c);
        case 1:return Drawing(c);
        case 2:return Loot(c);
        case 4:return Radar(c);
        default:return Personality(c);
    }
}
