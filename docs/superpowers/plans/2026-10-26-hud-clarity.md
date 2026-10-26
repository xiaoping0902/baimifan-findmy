# HUD 清晰度与人物信息修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 按用户截图重新排人物信息、修正未知血量伪满血、提供清晰中文与真实可用的精简菜单。

**Architecture:** 保留 UIKit 小窗口与 Metal/ImGui 绘制，保留全屏拖动、尺寸调节和独立顶部灵动岛。人物布局统一计算文本与射线锚点；动态生命值独立刷新；菜单状态完整接入 MFSettings；原生岛订阅实际统计。

**Tech Stack:** Objective-C++、UIKit、Metal、Dear ImGui 1.92、TrueType 中文字体、C++/UIKit 回归。

**Spec:** 本次用户消息及附图：武器具体名；`4头35  5甲105  6包`；`队号 : 人物ID`；干员和血条位于骨骼头上、距离位于脚下；射线接装备行中央；小玉品牌；移除无效开关；物资统计独立开关；字体清晰；血量准确。

## Global Constraints

- 不猜测游戏偏移或最大生命值；未知值明确表示未知。
- 全屏绘制窗口保持触摸穿透，菜单和灵动岛维持独立小窗口。
- 不破坏单一 HID bridge、旋转 bounds/center 布局、拖动与双向缩放、低耗空闲帧率。
- 不修改或提交任务开始前的未提交文件；精确 stage。
- 用户已授权直接推送既有 GitHub 分支并编译。

## Tasks

- [x] 人物信息与血条：修改 MFDrawingLayer.mm、MFGameReader 及必要布局 helper；在真实绘制 fixture 覆盖 25/100、未知、行顺序与射线终点。将血量刷新与慢速属性缓存解耦，未知不画满条。
- [x] 菜单：修改 UIPort 与 MFMenuPanel，移除未实现的自瞄/追踪等控制，品牌改小玉，保留绘制/物资/外观/设置的实际控制；独立接通 showLootStats，设置载入与保存一致。更新真实点击与缩放回归。
- [x] 字体：检查 full TTF 所需字形与动态字体密度，采用可复现的适中字重 TrueType；模拟器 fixture 使用生产字库，验证实际 Metal 截图。
- [x] 灵动岛：MFHUDIslandView 提供实时统计 API、系统半粗体数字和中文；MFMenuPanel 统计订阅由 delegate 接到 island；等待画面时不显示上次残留统计。测试计数变化、无效画面、触摸与无障碍。
- [ ] 集成：本地 preflight、entitlement 与 portable UI 回归；审查变更；精确提交推送，等待 GitHub arm64 IPA 和全部 UIKit 回归。下载实际预览和发布 IPA，核对 commit/version/digest 后交付。


## Review and validation

- Local: portable production-panel and health regressions pass; font 2/2, entitlement 3/3, preflight 194/194 pass. Apple simulator and arm64 build are verified by GitHub Actions after push.
- Independent review found no confirmed critical defect or drag/resize/island regression.
- SDK confirms HealthMAX+0x258 was incorrectly used as live HP. Current health now uses HealthSet and its CurrentValue fields with a separate 15 Hz cache.
- Known data limitation: PlayerState+0x470 is a player nickname, so the switch is named 人物名字. HeroID exists at +0x9F0, but no validated ID-to-operator-codename table is available in this checkout/SDK.
- Known data limitation: held-weapon dictionary names are shown without a prefix; unrecognized IDs remain 武器未知. Loot knife IDs have not been falsely reused as held-weapon IDs.
