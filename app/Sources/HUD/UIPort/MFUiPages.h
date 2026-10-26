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
    c.card(0,154,c.width,174,"面板控制");
    c.toggle(14,190,c.width-28,"绘制总开关",c.st.feat[DrawingHuman],"drawing_master");
    c.slider(14,232,c.width-28,"面板大小",c.st.uiScale,kPanelScaleMinimum,kPanelScaleMaximum,"%.0f%%",100*kPanelDefaultWidthRatio,"panel_size",.01f/kPanelDefaultWidthRatio);
    c.text(14,290,13,c.tc.textMuted,"拖动标题移动，右下角缩放");
    return 328;
}
static float Drawing(Canvas& c) {
    static const char* names[]={"人机","骨骼","射线","血量","人物名字","队伍与ID","武器名字","背敌提示","距离","头甲包"};
    static const int indices[]={DrawingBot,DrawingSkeleton,DrawingRay,DrawingHealth,DrawingName,DrawingTeam,DrawingWeapon,DrawingOffscreen,DrawingDistance,DrawingEquipment};
    c.card(0,0,c.width,476,"人物信息");
    for(int i=0;i<IM_ARRAYSIZE(indices);++i){
        char id[32];snprintf(id,sizeof(id),"drawing_%d",indices[i]);
        c.toggle(14,34+i*36,c.width-28,names[i],c.st.feat[indices[i]],id);
    }
    c.toggle(14,394,c.width-28,"显示队友",c.st.showTeammates,"show_teammates");
    c.toggle(14,430,c.width-28,"雷达",c.st.radarEnabled,"radar_enabled");
    c.card(0,488,c.width,130,"显示范围");
    c.slider(14,524,c.width-28,"骨骼距离",c.st.skeletonDistance,20,500,"%.0fm",1,"skeleton_distance",10);
    c.slider(14,566,c.width-28,"背敌距离",c.st.backEnemyDistance,20,500,"%.0fm",1,"back_enemy_distance",10);
    return 618;
}
static float Loot(Canvas& c) {
    c.card(0,0,c.width,190,"物资显示");
    c.toggle(14,34,c.width-28,"物资标记",c.st.lootEnabled,"loot_enabled");
    c.toggle(14,70,c.width-28,"物资名字",c.st.lootNamesEnabled,"loot_names");
    c.toggle(14,106,c.width-28,"盒子标记",c.st.boxesEnabled,"loot_boxes");
    c.toggle(14,142,c.width-28,"物资统计",c.st.lootStatsEnabled,"loot_stats");
    c.card(0,202,c.width,228,"筛选与距离");
    c.slider(14,238,c.width-28,"最低等级",c.st.minLootLevel,0,6,"%.0f",1,"loot_level",1);
    c.slider(14,280,c.width-28,"最低价值",c.st.minLootValue,0,200000,"%.0f",1,"loot_value",1000);
    c.slider(14,322,c.width-28,"物资距离",c.st.lootDistance,20,500,"%.0fm",1,"loot_distance",10);
    c.slider(14,364,c.width-28,"盒子距离",c.st.boxDistance,20,500,"%.0fm",1,"box_distance",10);
    c.text(14,406,12,c.tc.textMuted,"等级和价值设为 0 时显示全部");
    return 430;
}
static float Personality(Canvas& c) {
    c.card(0,0,c.width,394,"界面与字号");
    const char* themes[]={"纯白","雾蓝","浅紫","柔粉"};
    if(c.segment(14,36,c.width-28,"主题",themes,4,c.st.theme,"theme")){
        const float hues[]={.587f,.587f,.72f,.96f};c.st.accentHue=hues[c.st.theme];
    }
    c.slider(14,80,c.width-28,"背景透明",c.st.bgAlpha,.85f,1,"%.0f%%",100,"background_alpha");
    c.slider(14,122,c.width-28,"面板大小",c.st.uiScale,kPanelScaleMinimum,kPanelScaleMaximum,"%.0f%%",100*kPanelDefaultWidthRatio,"panel_size",.01f/kPanelDefaultWidthRatio);
    c.slider(14,164,c.width-28,"人物字号",c.st.espFontScale,.85f,1.5f,"%.0f%%",100,"esp_font_scale");
    c.slider(14,206,c.width-28,"物资字号",c.st.lootFontScale,.85f,1.5f,"%.0f%%",100,"loot_font_scale");
    c.slider(14,248,c.width-28,"骨骼粗细",c.st.boneLineWidth,.5f,3,"%.1f",1,"personality_bone_width");
    const char* styles[]={"细线","胶囊","分段"};
    int style=ImClamp(c.st.healthBarStyle,0,2);
    if(c.segment(14,294,c.width-28,"血条样式",styles,3,style,"health_style"))c.st.healthBarStyle=style;
    c.text(14,346,12,c.tc.textMuted,"灵动岛位于屏幕顶部中央");
    c.card(0,406,c.width,86,"绘制颜色");
    c.color(14,442,c.width-28,"骨骼",c.st.humanSkeletonColor,"skeleton_color");
    return 492;
}
static float DrawPage(Canvas& c,int tab) {
    switch(tab){
        case 0:return Home(c);
        case 1:return Drawing(c);
        case 2:return Loot(c);
        default:return Personality(c);
    }
}
