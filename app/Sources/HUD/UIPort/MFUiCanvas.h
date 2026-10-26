#pragma once
/* 小玉原版 ios_ui.h（原样搬运）：Canvas 设计系统、面板外框、分页、灵动岛。 */
#include "MFUiTheme.h"
// Presentation only: persistent settings remain in UIState and main.cpp.
namespace ios {
static float Damp(float from,float to,float rate=20.0f) {
    return ImLerp(from,to,1.0f-std::exp(-rate*ImClamp(ImGui::GetIO().DeltaTime,0.0f,.1f)));
}
static float Motion(UIState& st,ImGuiID id,float target) {
    ImGuiStorage* storage=ImGui::GetStateStorage();
    float value=storage->GetFloat(id,target);
    value=Damp(value,target);
    if(std::fabs(value-target)<.001f)value=target;
    else st.animationActive=true;
    storage->SetFloat(id,value);
    return value;
}
struct Canvas {
    ImDrawList* dl; ImFont* font; UIState& st; ThemeColors tc;
    ImVec2 origin; float s; float width; float viewportHeight; bool blockClick;
    ImVec2 p(float x,float y) const {return ImVec2(origin.x+x*s,origin.y+y*s);}
    void text(float x,float y,float size,ImU32 color,const char* value) {
        DrawText(dl,font,size*s,p(x,y),color,value);
    }
    void rect(float x,float y,float w,float h,ImU32 color,float radius=12) {
        if(w>0&&h>0)dl->AddRectFilled(p(x,y),p(x+w,y+h),color,radius*s);
    }
    bool hit(float x,float y,float w,float h,const char* id) {
#ifdef HEIHUANG_UI_TEST_ITEM
        if(ImGui::IsRectVisible(p(x,y),p(x+w,y+h)))HEIHUANG_UI_TEST_ITEM(id,p(x,y),ImVec2(w*s,h*s));
#endif
        ImGui::SetCursorScreenPos(p(x,y));
        bool pressed=ImGui::InvisibleButton(id,ImVec2(ImMax(w*s,1.0f),ImMax(h*s,1.0f)));
        return pressed&&!blockClick&&!ImGui::IsMouseDragPastThreshold(0,8*s);
    }
    void card(float x,float y,float w,float h,const char* title) {
        rect(x,y,w,h,tc.surface,15);
        dl->AddRect(p(x,y),p(x+w,y+h),tc.border,15*s,0,ImMax(.5f*s,.5f));
        if(title)text(x+14,y+12,14,tc.textMuted,title);
    }
    void section(float x,float y,const char* title){text(x,y,14,tc.textMuted,title);}
    void info(float x,float y,float w,const char* label,const char* value,ImU32 color=0) {
        text(x,y+10,14,tc.textMuted,label);
        float tw=TextSize(font,13*s,value).x/s;
        text(x+w-tw,y+11,13,color?color:tc.textMuted,value);
    }
    void switchShape(float x,float y,bool value,ImGuiID id) {
        const float t=Motion(st,id^0x635091u,value?1.0f:0.0f);
        rect(x,y,38,23,MixColor(IM_COL32(228,228,233,(tc.surface>>24)&255),WithAlpha(IM_COL32(52,199,89,255),(tc.surface>>24)&255),t),12);
        ImVec2 center=p(x+11.5f+15*t,y+11.5f);
        dl->AddCircleFilled(ImVec2(center.x,center.y+s),9.6f*s,MultiplyAlpha(IM_COL32(0,0,0,25),(tc.text>>24)/255.0f),20);
        dl->AddCircleFilled(center,9.5f*s,WithAlpha(IM_COL32_WHITE,(tc.text>>24)&255),20);
    }
    bool toggle(float x,float y,float w,const char* label,bool& value,const char* id) {
        bool changed=hit(x,y,w,36,id);
        if(changed){value=!value;st.configDirty=true;}
        ImGuiID key=ImGui::GetID(id);
        text(x,y+9,15,tc.text,label);
        switchShape(x+w-38,y+6.5f,value,key);
        return changed;
    }
    bool tile(float x,float y,float w,const char* label,bool value,const char* id) {
        const bool changed=hit(x,y,w,48,id);
        ImGuiID key=ImGui::GetID(id);
        const float t=Motion(st,key^0x1834u,value?1.0f:0.0f);
        rect(x,y,w,48,MixColor(tc.surface,tc.accent,.035f*t),13);
        dl->AddRect(p(x,y),p(x+w,y+48),MixColor(tc.border,WithAlpha(tc.accent,65),t),13*s,0,ImMax(.5f,s*.7f));
        float size=12;
        const float room=ImMax(1.0f,w-62);
        float extent=TextSize(font,size*s,label).x/s;
        if(extent>room)size=ImMax(8.0f,size*room/extent);
        text(x+10,y+(48-size)*.5f-1,size,value?tc.text:tc.textMuted,label);
        switchShape(x+w-47,y+12.5f,value,key);
        if(changed)st.configDirty=true;
        return changed;
    }
    bool segment(float x,float y,float w,const char* label,const char* const* options,int count,int& selected,const char* id) {
        float labelW=(label&&*label)?ImMin(83.0f,w*.30f):0;
        if(labelW)text(x,y+10,14,tc.text,label);
        float cx=x+labelW,cw=w-labelW,part=(cw-4)/count;
        rect(cx,y+4,cw,29,MixColor(tc.surface,tc.textFaint,.14f),9);
        bool changed=false;
        ImGui::PushID(id);
        for(int i=0;i<count;++i){
            ImGui::PushID(i);
            if(hit(cx+2+part*i,y+6,part,25,"##segment")){selected=i;changed=true;st.configDirty=true;}
            ImGui::PopID();
        }
        // One geometry calculation drives the selected background and hit areas.
        float visual=Motion(st,ImGui::GetID("##selected"),float(selected));
        rect(cx+2+part*visual,y+7,part,25,MultiplyAlpha(IM_COL32(0,0,0,16),((tc.text>>24)&255)/255.0f),7);
        rect(cx+2+part*visual,y+6,part,25,tc.surface,7);
        for(int i=0;i<count;++i){
            float fs=11;
            float tw=TextSize(font,fs*s,options[i]).x/s;
            if(tw>part-8)fs=ImMax(8.0f,fs*(part-8)/tw);
            DrawTextCentered(dl,font,fs*s,p(cx+2+part*i,y+6),p(cx+2+part*(i+1),y+31),i==selected?tc.text:tc.textMuted,options[i]);
        }
        ImGui::PopID();
        return changed;
    }
    bool slider(float x,float y,float w,const char* label,float& value,float lo,float hi,const char* format,float multiplier,const char* id,float step=0) {
        char valueText[48];snprintf(valueText,sizeof(valueText),format,double(value*multiplier));
        const float valueW=ImMax(43.0f,TextSize(font,10*s,valueText).x/s+4);
        const float labelW=ImMin(89.0f,w*.34f);
        const float trackX=x+labelW,trackW=ImMax(24.0f,w-labelW-valueW-8);
        text(x,y+12,14,tc.text,label);
        const bool tapped=hit(trackX,y+4,trackW,32,id);
        const bool active=ImGui::IsItemActive();
        // Capture pointer mapping once so a live panel resize cannot feed back
        // into this gesture when the track moves or changes width.
        ImGuiStorage* storage=ImGui::GetStateStorage();
        const ImGuiID key=ImGui::GetID(id);
        const float currentLeft=p(trackX+8,0).x;
        const float currentSpan=ImMax(trackW-16,1.0f)*s;
        if(ImGui::IsItemActivated()){
            storage->SetFloat(key^0x741u,currentLeft);
            storage->SetFloat(key^0x742u,currentSpan);
        }
        bool changed=false;
        // Wait for horizontal intent; vertical scrolling must never change a value.
        const bool dragging=active&&st.gesturePage==st.tab&&st.gestureAxis==1;
        if((dragging||tapped)&&!blockClick&&hi>lo){
            const float left=storage->GetFloat(key^0x741u,currentLeft);
            const float span=storage->GetFloat(key^0x742u,currentSpan);
            const float pointer=ImGui::GetIO().MousePos.x;
            // ImGui rounds pointer positions to whole framebuffer points.
            // Keep both endpoints reachable on compact, fractional tracks.
            float t=pointer<=left+1.0f?0.0f:pointer>=left+span-1.0f?1.0f:
                ImClamp((pointer-left)/span,0.0f,1.0f);
            float next=lo+t*(hi-lo);
            if(step>0)next=lo+std::round((next-lo)/step)*step;
            next=ImClamp(next,lo,hi);
            changed=std::fabs(next-value)>.00001f;
            value=next;
            if(changed)st.configDirty=true;
        }
        float t=hi>lo?ImClamp((value-lo)/(hi-lo),0.0f,1.0f):0;
        rect(trackX,y+4,trackW,32,tc.track,10);
        rect(trackX+t*(trackW-16),y+6,16,28,MixColor(tc.accent,tc.surface,.32f),8);
        snprintf(valueText,sizeof(valueText),format,double(value*multiplier));
        float tw=TextSize(font,10*s,valueText).x/s;
        text(x+w-tw,y+14,10,tc.textMuted,valueText);
        return changed;
    }
    bool button(float x,float y,float w,const char* label,const char* id,bool danger=false) {
        bool clicked=hit(x,y,w,34,id);
        bool hovered=ImGui::IsItemHovered();
        ImU32 color=danger?tc.danger:tc.accent;
        rect(x,y,w,34,WithAlpha(color,hovered?28:15),9);
        DrawTextCentered(dl,font,12*s,p(x,y),p(x+w,y+34),color,label);
        return clicked;
    }
    void metric(float x,float y,float w,const char* label,const char* value,ImU32 signal) {
        card(x,y,w,78,nullptr);
        dl->AddCircleFilled(p(x+14,y+18),2.5f*s,signal,12);
        text(x+22,y+12,10,tc.textMuted,label);
        float fs=23,tw=TextSize(font,fs*s,value).x/s;
        if(tw>w-24)fs*= (w-24)/tw;
        text(x+12,y+37,fs,tc.text,value);
    }
    bool swatch(float x,float y,ImU32 color,bool selected,const char* id) {
        bool changed=hit(x-4,y-4,27,27,id);
        dl->AddCircleFilled(p(x+9,y+9),9*s,color,24);
        if(selected)dl->AddCircle(p(x+9,y+9),12*s,tc.accent,24,1.5f*s);
        return changed;
    }
    bool color(float x,float y,float w,const char* label,ImVec4& value,const char* id) {
        text(x,y+10,14,tc.text,label);
        ImGui::PushID(id);
        // The full labeled row owns the same unique ID as its color state.
        if(hit(x,y,w,36,id))ImGui::OpenPopup("##color");
        rect(x+w-26,y+8,22,22,ImGui::ColorConvertFloat4ToU32(value),6);
        bool changed=false;
        ImGui::SetNextWindowSize(ImVec2(280*s,0));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(14*s,14*s));
        ImGui::PushStyleVar(ImGuiStyleVar_PopupRounding,14*s);
        ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding,6*s);
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding,ImVec2(5*s,5*s));
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing,ImVec2(6*s,8*s));
        ImGui::PushStyleColor(ImGuiCol_Text,tc.text);
        ImGui::PushStyleColor(ImGuiCol_PopupBg,tc.surface);
        ImGui::PushStyleColor(ImGuiCol_Border,tc.border);
        ImGui::PushStyleColor(ImGuiCol_FrameBg,tc.track);
        ImGui::PushStyleColor(ImGuiCol_FrameBgHovered,tc.accentSoft);
        ImGui::PushStyleColor(ImGuiCol_FrameBgActive,tc.accentSoft);
        if(ImGui::BeginPopup("##color")){
            /* 新版 ImGui 删掉了 ImFont::FontSize；统一用 14px 与当前字号的比例 */
            ImGui::SetWindowFontScale(ImMax(0.6f, 14.0f * s / ImMax(1.0f, ImGui::GetFontSize())));
            ImGui::TextUnformatted(label);
            const ImVec4 presets[]={ImVec4(1,.08f,.08f,1),ImVec4(.10f,1,.20f,1),
                ImVec4(.12f,.48f,1,1),ImVec4(1,.85f,.08f,1),ImVec4(1,1,1,1)};
            const char* names[]={"红","绿","蓝","黄","白"};
            for(int i=0;i<IM_ARRAYSIZE(presets);++i){
                if(i)ImGui::SameLine();
                ImGui::PushID(i);
                ImVec4 preview=presets[i];
                if(ImGui::ColorButton(names[i],preview,ImGuiColorEditFlags_NoTooltip,ImVec2(30*s,26*s))){
                    value=presets[i];changed=true;
                }
#ifdef HEIHUANG_UI_TEST_ITEM
                HEIHUANG_UI_TEST_ITEM("color_preset",ImGui::GetItemRectMin(),ImGui::GetItemRectSize());
#endif
                ImGui::PopID();
            }
            ImGui::Separator();
            ImGui::PushItemWidth(252*s);
            /* [M5.178] 原版直接对 &value.x 取址；ObjC++ 下对成员取址要走局部数组 */
            {
                float col[4] = {value.x, value.y, value.z, value.w};
                if (ImGui::ColorPicker4("##picker", col,
                        ImGuiColorEditFlags_NoSidePreview|ImGuiColorEditFlags_NoSmallPreview|
                        ImGuiColorEditFlags_AlphaBar|ImGuiColorEditFlags_DisplayRGB|
                        ImGuiColorEditFlags_NoOptions)) {
                    value = ImVec4(col[0], col[1], col[2], col[3]);
                    changed = true;
                }
            }
            ImGui::PopItemWidth();
            ImGui::EndPopup();
        }
        ImGui::PopStyleColor(6);
        ImGui::PopStyleVar(5);
        if(changed)st.configDirty=true;
        ImGui::PopID();
        return changed;
    }
};

#include "MFUiPages.h"

static bool UpdateScroll(UIState& st,ImVec2 from,ImVec2 to,float s,float viewHeight) {
    ImGuiIO& io=ImGui::GetIO();
    const int tab=st.tab;
    float& offset=st.pageOffsets[tab];float& speed=st.pageSpeeds[tab];
    const float dt=ImClamp(io.DeltaTime,.0001f,.1f);
    const float maximum=ImMax(0.0f,st.pageHeights[tab]-viewHeight);
    const bool inside=io.MousePos.x>=from.x&&io.MousePos.x<=to.x&&io.MousePos.y>=from.y&&io.MousePos.y<=to.y;
    const bool popup=ImGui::IsPopupOpen(nullptr,ImGuiPopupFlags_AnyPopupId);
    if(inside&&!popup&&io.MouseWheel!=0)speed-=io.MouseWheel*950.0f;
    if(inside&&!popup&&ImGui::IsMouseClicked(0)){
        st.gesturePage=tab;st.gestureAxis=0;st.gestureStart=io.MousePos;
        st.gestureScrollStart=offset;st.gestureLastY=io.MousePos.y;speed=0;
    }
    bool blocked=st.gesturePage==tab&&st.gestureAxis==2;
    if(st.gesturePage==tab&&io.MouseDown[0]){
        const float dx=(io.MousePos.x-st.gestureStart.x)/s,dy=(io.MousePos.y-st.gestureStart.y)/s;
        if(st.gestureAxis==0){
            if(std::fabs(dy)>8&&std::fabs(dy)>std::fabs(dx)*1.15f)st.gestureAxis=2;
            else if(std::fabs(dx)>8)st.gestureAxis=1;
        }
        if(st.gestureAxis==2){
            blocked=true;
            ImGui::ClearActiveID();
            offset=st.gestureScrollStart-dy;
            const float instant=(st.gestureLastY-io.MousePos.y)/(s*dt);
            speed=ImClamp(ImLerp(speed,instant,.45f),-2400.0f,2400.0f);
        }
        st.gestureLastY=io.MousePos.y;
    }else{
        offset+=speed*(1.0f-std::exp(-12*dt))/12.0f;
        speed*=std::exp(-12*dt);
        if(std::fabs(speed)<2)speed=0;
    }
    const float clamped=ImClamp(offset,0.0f,maximum);
    if(clamped!=offset)speed=0;
    offset=clamped;
    if(speed!=0.0f)st.animationActive=true;
    return blocked;
}
static void DrawIslandCapsule(ImDrawList* dl, ImVec2 p0, ImVec2 p1,
                              float s, const ThemeColors& tc, float hoverAmount,
                              float pressAmount, float opacity)
{
    const ImVec2 center((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);
    const float pressScale = 1.0f - 0.025f * ImClamp(pressAmount, 0.0f, 1.0f);
    const ImVec2 half((p1.x - p0.x) * 0.5f * pressScale,
                      (p1.y - p0.y) * 0.5f * pressScale);
    p0 = ImVec2(center.x - half.x, center.y - half.y);
    p1 = ImVec2(center.x + half.x, center.y + half.y);
    const float radius = (p1.y - p0.y) * 0.5f;
    const float hover = ImClamp(hoverAmount, 0.0f, 1.0f);
    const ImU32 base = MultiplyAlpha(MixColor(IM_COL32(7, 10, 14, 248),
                                               IM_COL32(18, 23, 29, 252), hover), opacity);
    const ImU32 outerBorder = MultiplyAlpha(MixColor(IM_COL32(255, 255, 255, 32),
                                                      tc.accent, 0.20f + hover * 0.24f), opacity);
    const ImU32 innerBorder = MultiplyAlpha(IM_COL32(255, 255, 255, 18), opacity);

    dl->AddRectFilled(p0, p1, base, radius);
    dl->AddRect(p0, p1, outerBorder, radius, 0, ImMax(1.0f, 1.25f * s));
    dl->AddRect(ImVec2(p0.x + 2.0f * s, p0.y + 2.0f * s),
                ImVec2(p1.x - 2.0f * s, p1.y - 2.0f * s),
                innerBorder, radius - 2.0f * s, 0, ImMax(1.0f, 0.8f * s));

    const float glowW = ImMin((p1.x - p0.x) * 0.36f, 74.0f * s);
    dl->AddLine(ImVec2(p0.x + radius * 0.72f, p0.y + 1.0f * s),
                ImVec2(p0.x + radius * 0.72f + glowW, p0.y + 1.0f * s),
                MultiplyAlpha(tc.accent, opacity * (0.28f + hover * 0.18f)),
                ImMax(1.0f, 1.15f * s));

}

static void DrawIslandRadar(ImDrawList* dl, ImVec2 center, float s,
                            const ThemeColors& tc, float pulse, float opacity)
{
    const float wave = 0.5f + 0.5f * std::sin(pulse * 6.2831853f);
    const ImU32 accent = MultiplyAlpha(tc.accent, opacity);
    dl->AddCircleFilled(center, 8.5f * s,
                        MultiplyAlpha(tc.accent, opacity * (0.08f + wave * 0.025f)), 20);
    dl->AddCircle(center, 5.8f * s, MultiplyAlpha(tc.accent, opacity * 0.68f), 20,
                  ImMax(1.0f, 1.0f * s));
    dl->AddCircleFilled(center, 2.1f * s, accent, 14);
    dl->AddLine(center, ImVec2(center.x + 3.8f * s, center.y - 2.8f * s),
                MultiplyAlpha(tc.accent, opacity * 0.88f), ImMax(1.0f, 1.05f * s));
}

static void DrawIslandBadge(ImDrawList* dl, ImFont* font, ImVec2 p0, ImVec2 p1,
                            float textSize, float s, ImU32 color, const char* text,
                            float opacity)
{
    const float rounding = (p1.y - p0.y) * 0.5f;
    dl->AddRectFilled(p0, p1, MultiplyAlpha(color, opacity * 0.13f), rounding);
    dl->AddRect(p0, p1, MultiplyAlpha(color, opacity * 0.42f), rounding, 0,
                ImMax(1.0f, 0.85f * s));
    DrawTextCentered(dl, font, textSize, p0, p1, MultiplyAlpha(color, opacity), text);
}

static void DrawIsland(UIState& st,ImVec2 screen,ImFont* font) {
    /* [M5.190] 面板已经展开时不再画灵动岛 —— 否则会浮在面板上方像个孤立的小黑条 */
    if (st.anim > 0.02f) return;
    const IslandLayout layout=ComputeIslandLayout(screen,st.islandYOffset);
    const float scale=layout.scale,fs=14.5f*scale;
    const bool showReal=st.realCount>0,showBot=st.botCount>0;
    // ---- 观战徽章（2026-09-15）----
    // 两种独立情况：
    //   observerCount>0  有人在观战你（好友观战 / 巡查）—— 用醒目的琥珀色提醒
    //   selfObserver     你自己处于观战状态（死亡观战/好友观战/巡查视角）
    // 数据由 esp.h readCamera() 读取，读不到合理值时一律为 false，不会误报。
    const bool showObs=st.observerCount>0;
    const bool showSelf=st.selfObserver;
    char real[32]={},bots[32]={},obs[32]={};
    if(showReal)snprintf(real,sizeof(real),"真人%d",st.realCount);
    if(showBot)snprintf(bots,sizeof(bots),"人机%d",st.botCount);
    if(showObs)snprintf(obs,sizeof(obs),"观战%d",st.observerCount);
    const char* selfTxt="观战中";
    const float rw=showReal?TextSize(font,fs,real).x+16*scale:0;
    const float bw=showBot?TextSize(font,fs,bots).x+16*scale:0;
    const float ow=showObs?TextSize(font,fs,obs).x+16*scale:0;
    const float sw=showSelf?TextSize(font,fs,selfTxt).x+16*scale:0;
    const int badgeN=(showReal?1:0)+(showBot?1:0)+(showObs?1:0)+(showSelf?1:0);
    const float gap=badgeN>1?7*scale:0;
    const float compact=108*scale;
    const float target=ImClamp(rw+bw+ow+sw+gap*(badgeN>1?badgeN-1:0)+64*scale,
                               compact,ImMax(compact,screen.x-20*scale));
    if(st.islandWidthVisual<=0)st.islandWidthVisual=target;
    st.islandWidthVisual=Damp(st.islandWidthVisual,target,16);
    const float w=st.islandWidthVisual,h=layout.height,y=layout.top;
    const ImVec2 p0((screen.x-w)*.5f,y),p1(p0.x+w,y+h);
    ImGui::SetNextWindowPos(p0);ImGui::SetNextWindowSize(ImVec2(w,h));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(0,0));
    ImGui::Begin("##ios_island",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoBackground|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoNav|ImGuiWindowFlags_NoFocusOnAppearing|ImGuiWindowFlags_NoBringToFrontOnFocus);
    // Keep both the visuals and hit area above a panel dragged underneath it.
    ImGui::BringWindowToDisplayFront(ImGui::GetCurrentWindow());
    ImGui::SetCursorScreenPos(p0);
#ifdef HEIHUANG_UI_TEST_ITEM
    HEIHUANG_UI_TEST_ITEM("island_toggle",p0,ImVec2(w,h));
#endif
    if(ImGui::InvisibleButton("island_toggle",ImVec2(w,h))&&!ImGui::IsMouseDragPastThreshold(0,8*scale))st.expanded=!st.expanded;
    st.islandHoverVisual=Damp(st.islandHoverVisual,ImGui::IsItemHovered()?1.0f:0.0f,18);
    st.islandPressVisual=Damp(st.islandPressVisual,ImGui::IsItemActive()?1.0f:0.0f,24);
    ImGui::End();ImGui::PopStyleVar();
    const ThemeColors tc=GetTheme(st.theme,st.bgAlpha,st.accentHue);
    const float a=st.islandAlpha;
    ImDrawList* dl=ImGui::GetForegroundDrawList();
    DrawIslandCapsule(dl,p0,p1,scale,tc,st.islandHoverVisual,st.islandPressVisual,a);
    DrawIslandRadar(dl,ImVec2(p0.x+23*scale,layout.centerY()),scale,tc,std::fmod(st.time*.72f,1.0f),a);
    if(badgeN==0){
        DrawText(dl,font,fs,ImVec2(p0.x+42*scale,layout.centerY()-TextSize(font,fs,"运行中").y*.5f),MultiplyAlpha(IM_COL32(238,242,247,255),a),"运行中");
        return;
    }
    const float badgeH=28*scale,badgeY=layout.centerY()-badgeH*.5f;
    float badgeX=p0.x+43*scale;
    dl->PushClipRect(ImVec2(p0.x+36*scale,p0.y),ImVec2(p1.x-8*scale,p1.y),true);
    if(showObs){
        DrawIslandBadge(dl,font,ImVec2(badgeX,badgeY),ImVec2(badgeX+ow,badgeY+badgeH),fs,scale,IM_COL32(255,176,32,255),obs,a);
        badgeX+=ow+gap;
    }
    if(showSelf){
        DrawIslandBadge(dl,font,ImVec2(badgeX,badgeY),ImVec2(badgeX+sw,badgeY+badgeH),fs,scale,IM_COL32(96,165,250,255),selfTxt,a);
        badgeX+=sw+gap;
    }
    if(showReal){
        DrawIslandBadge(dl,font,ImVec2(badgeX,badgeY),ImVec2(badgeX+rw,badgeY+badgeH),fs,scale,IM_COL32(255,101,111,255),real,a);
        badgeX+=rw+gap;
    }
    if(showBot)DrawIslandBadge(dl,font,ImVec2(badgeX,badgeY),ImVec2(badgeX+bw,badgeY+badgeH),fs,scale,IM_COL32(91,222,161,255),bots,a);
    dl->PopClipRect();
}
} // namespace ios

static void DrawBackgroundCover(ImDrawList* dl,const UIBackgroundTexture& image,
                                ImVec2 p0,ImVec2 p1,ImU32 tint,float rounding) {
    if(!image.id||image.width<=0||image.height<=0||p1.x<=p0.x||p1.y<=p0.y)return;
    const float drawAspect=(p1.x-p0.x)/(p1.y-p0.y);
    const float imageAspect=(float)image.width/(float)image.height;
    ImVec2 uv0(0,0),uv1(1,1);
    if(imageAspect>drawAspect){
        const float visible=drawAspect/imageAspect;
        uv0.x=(1.0f-visible)*.5f;uv1.x=uv0.x+visible;
    }else{
        const float visible=imageAspect/drawAspect;
        uv0.y=(1.0f-visible)*.5f;uv1.y=uv0.y+visible;
    }
    dl->AddImageRounded(image.id,p0,p1,uv0,uv1,tint,rounding,ImDrawFlags_RoundCornersBottomRight);
}

// Source-over layers with a single target opacity. Each weight describes a
// color contribution, so adding the white veil never makes the body more opaque.
static float BackgroundLayerAlpha(float opacity,float weight,float weightAbove) {
    const float remaining=1.0f-opacity*weightAbove;
    return weight>0&&remaining>.00001f?ImClamp(opacity*weight/remaining,0.0f,1.0f):0.0f;
}

static void RenderUI(UIState& st,ImVec2 screenSize,ImFont* font,ImTextureID brandLogoTexture,
                     const UIBackgroundTexture* backgroundTextures=nullptr,
                     int backgroundTextureCount=0,
                     const UIPanelLayout* hostedLayout=nullptr) {
    if(!font||screenSize.x<=0||screenSize.y<=0)return;
    ImGuiIO& io=ImGui::GetIO();
    const bool hosted=hostedLayout!=nullptr;
    st.hostedViewport=hosted;
    if(hosted&&!st.expanded){st.animationActive=false;return;}
    st.animationActive=io.MouseDown[0];
    st.tab=ImClamp(st.tab,0,kNavTabCount-1);
    const float boundedScale=ImClamp(st.uiScale,kPanelScaleMinimum,kPanelScaleMaximum);
    if(st.uiScale!=boundedScale){st.uiScale=boundedScale;st.configDirty=true;}
    st.uiScaleVisual=ImClamp(st.uiScaleVisual,kPanelScaleMinimum,kPanelScaleMaximum);
    const float dt=ImClamp(io.DeltaTime,0.0f,.1f);
    // UIKit animates the hosted window, including its last expanded frame.
    // Keep this canvas stable so the content and capture area never collapse
    // inside a second, independently animated coordinate system.
    st.anim=hosted?1.0f:ImClamp(st.anim+(st.expanded?dt/.32f:-dt/.25f),0.0f,1.0f);
    // Apply scale continuously, including while the size slider is held.
    st.uiScaleVisual=hosted?st.uiScale:ios::Damp(st.uiScaleVisual,st.uiScale,20);
    if(std::fabs(st.uiScaleVisual-st.uiScale)<.0001f)st.uiScaleVisual=st.uiScale;
    if(st.anim>0.001f&&st.anim<1.0f)st.animationActive=true;
    if(st.uiScaleVisual!=st.uiScale)st.animationActive=true;
    if(st.anim<=.001f){if(!hosted)ios::DrawIsland(st,screenSize,font);return;}
    const UIPanelLayout layout=hosted?*hostedLayout:ComputePanelLayout(screenSize,st.uiScaleVisual);
    const bool portrait=layout.portrait;
    const float baseW=layout.baseWidth,baseH=layout.baseHeight;
    const float scale=hosted?ImMin(screenSize.x/baseW,screenSize.y/baseH):layout.scale;
    const float reveal=SmootherStep(st.anim);
    const float s=scale;
    const float w=baseW*s,h=baseH*s;
    const ImVec2 finalPos(
        ImClamp(st.panelCenterXRatio*screenSize.x-w*.5f,12.0f,ImMax(12.0f,screenSize.x-w-12)),
        ImClamp(st.panelCenterYRatio*screenSize.y-h*.5f,12.0f,ImMax(12.0f,screenSize.y-h-12)));
    const IslandLayout island=ComputeIslandLayout(screenSize,st.islandYOffset);
    const float islandW=st.islandWidthVisual>0?st.islandWidthVisual:108*island.scale;
    const ImVec2 pos=hosted?ImVec2(0,0):ImLerp(ImVec2((screenSize.x-islandW)*.5f,island.top),finalPos,reveal);
    const ImVec2 size=hosted?ImVec2(w,h):ImVec2(ImLerp(islandW,w,reveal),ImLerp(island.height,h,reveal));
    const ImVec2 end(pos.x+size.x,pos.y+size.y);
    const float x=pos.x,y=pos.y;
    const float rounding=ImLerp(island.height*.5f,24*s,reveal);
    const float contentAlpha=SmootherStep((st.anim-.72f)/.28f);
    const ThemeColors theme=GetTheme(st.theme,st.bgAlpha,st.accentHue);
    ThemeColors tc=FadeTheme(theme,contentAlpha);
    ImDrawList* bg=ImGui::GetBackgroundDrawList();
    for(int i=3;i>=1;--i){float spread=i*4*s*reveal;bg->AddRectFilled(ImVec2(x-spread,y+8*s*reveal-spread),ImVec2(end.x+spread,end.y+8*s*reveal+spread),MultiplyAlpha(theme.shadow,.18f*reveal),rounding+spread);}
    ImGui::SetNextWindowPos(pos);ImGui::SetNextWindowSize(size);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(0,0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize,0);
    ImGui::Begin("##ios_panel",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoBackground|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoScrollbar|ImGuiWindowFlags_NoScrollWithMouse|ImGuiWindowFlags_NoNav|ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImDrawList* dl=ImGui::GetWindowDrawList();
    ios::Canvas shell{dl,font,st,tc,pos,s,baseW,baseH,false};
    const float top=60,side=portrait?84.0f:104.0f,titleH=64;
    bool showBackground=st.backgroundSlideshowEnabled&&backgroundTextures&&
                        backgroundTextureCount>=kUIBackgroundCount;
    if(showBackground)for(int i=0;i<kUIBackgroundCount;++i)
        showBackground=showBackground&&backgroundTextures[i].id&&
                       backgroundTextures[i].width>0&&backgroundTextures[i].height>0;
    const ImU32 panelColor=MultiplyAlpha(theme.panel,ImClamp(st.anim*5,0.0f,1.0f));
    const ImVec2 background0=shell.p(side,top+titleH);
    if(showBackground&&contentAlpha>.001f){
        // Header and sidebar retain the theme. The body is composed separately
        // below with the same opacity instead of stacking on another base coat.
        dl->PushClipRect(pos,ImVec2(end.x,background0.y),true);
        dl->AddRectFilled(pos,end,panelColor,rounding);dl->PopClipRect();
        dl->PushClipRect(ImVec2(pos.x,background0.y),ImVec2(background0.x,end.y),true);
        dl->AddRectFilled(pos,end,panelColor,rounding);dl->PopClipRect();
    }else dl->AddRectFilled(pos,end,panelColor,rounding);
    if(contentAlpha<=.001f){
        ImGui::End();ImGui::PopStyleVar(2);
        if(!hosted)ios::DrawIsland(st,screenSize,font);return;
    }
    if(showBackground){
        const UIBackgroundBlend blend=ComputeUIBackgroundBlend(st.time);
        const ImVec2 background1=end;
        const float opacity=((panelColor>>24)&255)/255.0f;
        const float whiteWeight=contentAlpha*(58.0f/255.0f);
        const float imageWeight=contentAlpha-whiteWeight;
        const float nextWeight=imageWeight*blend.nextAlpha;
        const float currentWeight=imageWeight-nextWeight;
        const float baseOpacity=BackgroundLayerAlpha(opacity,1.0f-contentAlpha,contentAlpha);
        const float currentOpacity=BackgroundLayerAlpha(opacity,currentWeight,whiteWeight+nextWeight);
        const float nextOpacity=BackgroundLayerAlpha(opacity,nextWeight,whiteWeight);
        const float whiteOpacity=BackgroundLayerAlpha(opacity,whiteWeight,0.0f);
        ImGui::PushClipRect(background0,background1,true);
        dl->AddRectFilled(background0,background1,
                          WithAlpha(theme.panel,(int)(baseOpacity*255+.5f)),
                          rounding,ImDrawFlags_RoundCornersBottomRight);
        DrawBackgroundCover(dl,backgroundTextures[blend.current],background0,background1,
                            MultiplyAlpha(IM_COL32_WHITE,currentOpacity),rounding);
        if(blend.nextAlpha>.001f)
            DrawBackgroundCover(dl,backgroundTextures[blend.next],background0,background1,
                                MultiplyAlpha(IM_COL32_WHITE,nextOpacity),rounding);
        dl->AddRectFilled(background0,background1,
                          MultiplyAlpha(IM_COL32_WHITE,whiteOpacity),
                          rounding,ImDrawFlags_RoundCornersBottomRight);
        ImGui::PopClipRect();
    }
    // Draw the shared theme background once, including both header rows, so
    // transparency does not accumulate differently across panel sections.
    dl->AddLine(shell.p(0,top),shell.p(baseW,top),tc.divider,ImMax(.5f,s*.6f));
    dl->AddLine(shell.p(side,top),shell.p(side,baseH),tc.divider,ImMax(.5f,s*.6f));
    dl->AddLine(shell.p(side,top+titleH),shell.p(baseW,top+titleH),tc.divider,ImMax(.5f,s*.6f));
    const bool disabled=st.anim<.98f||!st.expanded;
    if(disabled)ImGui::BeginDisabled();
    // Header-only drag region never covers navigation or content controls.
    if(!hosted){
        shell.hit(0,0,baseW-214,top,"panel_drag");
        if(ImGui::IsItemActivated()){
            st.panelDragStartMouse=io.MousePos;
            st.panelDragStartXRatio=(x+w*.5f)/screenSize.x;
            st.panelDragStartYRatio=(y+h*.5f)/screenSize.y;
        }
        if(ImGui::IsItemActive()){
            const float nx=st.panelDragStartXRatio*screenSize.x+io.MousePos.x-st.panelDragStartMouse.x;
            const float ny=st.panelDragStartYRatio*screenSize.y+io.MousePos.y-st.panelDragStartMouse.y;
            st.panelCenterXRatio=ImClamp(nx,w*.5f+12,screenSize.x-w*.5f-12)/screenSize.x;
            st.panelCenterYRatio=ImClamp(ny,h*.5f+12,screenSize.y-h*.5f-12)/screenSize.y;
            st.configDirty=true;ImGui::SetMouseCursor(ImGuiMouseCursor_ResizeAll);
        }
    }
    if(brandLogoTexture){
        dl->AddImageRounded(brandLogoTexture,shell.p(18,11),shell.p(56,49),
                            ImVec2(0,0),ImVec2(1,1),MultiplyAlpha(IM_COL32_WHITE,contentAlpha),11*s);
    }else{
        shell.rect(18,11,38,38,tc.accentSoft,11);
        DrawTextCentered(dl,font,19*s,shell.p(18,11),shell.p(56,49),tc.accent,"玉");
    }
    shell.text(66,20,18,tc.text,"小玉");
    char status[32];ImU32 tone=tc.success;
    if(st.tab==1)snprintf(status,sizeof(status),"%d / %d",CountEnabledDrawing(st),kVisibleDrawingItemCount);
    else if(st.tab==2){snprintf(status,sizeof(status),"物资 %d",st.lootCount);tone=tc.warning;}
    else snprintf(status,sizeof(status),"运行正常");
    shell.rect(baseW-207,18,83,25,WithAlpha(tone,22),13);
    DrawTextCentered(dl,font,10.5f*s,shell.p(baseW-203,18),shell.p(baseW-128,43),tone,status);
    if(shell.hit(baseW-94,14,32,32,"header_minimize"))st.expanded=false;
    if(ImGui::IsItemHovered())ImGui::SetTooltip("收起面板");
    shell.rect(baseW-94,14,32,32,WithAlpha(tc.textFaint,18),16);
    dl->AddLine(shell.p(baseW-84,30),shell.p(baseW-72,30),tc.textMuted,ImMax(1.0f,1.8f*s));
    bool close=shell.hit(baseW-50,14,32,32,"header_exit");
    if(ImGui::IsItemHovered())ImGui::SetTooltip("退出程序");
    shell.rect(baseW-50,14,32,32,WithAlpha(tc.textFaint,18),16);
    DrawPowerIcon(dl,shell.p(baseW-34,30),13*s,tc.textMuted);
    if(close)st.wantExit=true;
    const char* labels[]={"主页","人物","物资","外观"};
    const char* subtitles[]={"","","",""};
    const int navIcons[]={0,1,4,5};
    ImGui::PushID("navigation");
    for(int i=0;i<kNavTabCount;i++){
        ImGui::PushID(i);
        bool pressed=shell.hit(10,top+15+i*49,side-20,43,"nav");
        if(pressed&&st.tab!=i){st.tab=i;st.pageReveal=0;st.gesturePage=-1;for(float& v:st.pageSpeeds)v=0;}
        float selected=ios::Motion(st,ImGui::GetID("selected"),st.tab==i?1.0f:0.0f);
        shell.rect(10,top+15+i*49,side-20,43,MultiplyAlpha(tc.accentSoft,selected),11);
        ImU32 color=MixColor(tc.textMuted,tc.accent,selected);
        DrawNavIcon(dl,navIcons[i],shell.p(28,top+36.5f+i*49),17*s,color);
        shell.text(43,top+28+i*49,14,color,labels[i]);
        ImGui::PopID();
    }
    ImGui::PopID();
    shell.text(side+20,top+14,21,tc.text,labels[st.tab]);
    shell.text(side+72,top+23,11,tc.textFaint,subtitles[st.tab]);
    if(st.visualTab!=st.tab){st.visualTab=st.tab;st.pageReveal=0;}
    st.pageReveal=ios::Damp(st.pageReveal,1,24);
    if(st.pageReveal<.999f)st.animationActive=true;
    else st.pageReveal=1.0f;
    float bodyX=side+20,bodyY=top+titleH+16,bodyW=baseW-side-40,bodyH=baseH-bodyY-18;
    ImVec2 body0=shell.p(bodyX,bodyY),body1=shell.p(bodyX+bodyW,bodyY+bodyH);
    bool block=disabled||ios::UpdateScroll(st,body0,body1,s,bodyH);
    ImGui::PushClipRect(body0,body1,true);
    ImGui::PushID(st.tab);
    ThemeColors pageTheme=tc;
    if(showBackground){
        pageTheme.surface=MultiplyAlpha(pageTheme.surface,.82f);
        pageTheme.surfaceHover=MultiplyAlpha(pageTheme.surfaceHover,.86f);
        pageTheme.track=MultiplyAlpha(pageTheme.track,.84f);
        pageTheme.border=MultiplyAlpha(pageTheme.border,1.35f);
    }
    ios::Canvas page{dl,font,st,FadeTheme(pageTheme,.7f+.3f*st.pageReveal),shell.p(bodyX,bodyY-st.pageOffsets[st.tab]),s,bodyW,bodyH,block};
    st.pageHeights[st.tab]=ios::DrawPage(page,st.tab);
    ImGui::PopID();
    ImGui::PopClipRect();
    const float maxScroll=ImMax(0.0f,st.pageHeights[st.tab]-bodyH);
    st.pageOffsets[st.tab]=ImClamp(st.pageOffsets[st.tab],0.0f,maxScroll);
    if(maxScroll>0){
        float thumb=ImMax(28.0f,bodyH*bodyH/st.pageHeights[st.tab]);
        float thumbY=(bodyH-thumb)*st.pageOffsets[st.tab]/maxScroll;
        shell.rect(baseW-7,bodyY+thumbY,3,thumb,WithAlpha(tc.textFaint,110),2);
    }
    if(!io.MouseDown[0]){st.gesturePage=-1;st.gestureAxis=0;}
    shell.hit(baseW-25,baseH-25,25,25,"resize");
    if(ImGui::IsItemActivated()){
        st.resizeStartScale=st.uiScale;st.resizeStartMouse=io.MousePos;
        st.resizeStartHalfSize=ImVec2(w,h);st.resizeCorner=3;
    }
    st.resizing=ImGui::IsItemActive();
    if(st.resizing){
        float dx=(io.MousePos.x-st.resizeStartMouse.x)/st.resizeStartHalfSize.x;
        float dy=(io.MousePos.y-st.resizeStartMouse.y)/st.resizeStartHalfSize.y;
        const float next=ImClamp(st.resizeStartScale*(1+(hosted?1.0f:2.0f)*(std::fabs(dx)>std::fabs(dy)?dx:dy)),kPanelScaleMinimum,kPanelScaleMaximum);
        if(std::fabs(next-st.uiScale)>.00001f){st.uiScale=next;st.configDirty=true;}
        ImGui::SetMouseCursor(ImGuiMouseCursor_ResizeNWSE);
    }else st.resizeCorner=-1;
    dl->AddLine(shell.p(baseW-16,baseH-9),shell.p(baseW-9,baseH-16),WithAlpha(tc.textFaint,130),1.5f*s);
    dl->AddLine(shell.p(baseW-11,baseH-9),shell.p(baseW-9,baseH-11),WithAlpha(tc.textFaint,130),1.5f*s);
    if(disabled)ImGui::EndDisabled();
    ImGui::End();ImGui::PopStyleVar(2);
    if(!hosted)ios::DrawIsland(st,screenSize,font);
}
