# 干员身份、模式读取与无背景统计

本批承接用户对所有英雄显示未知、对决人机不显示、物资名称和价值缺失的反馈，同时完成已确认的 FPS、背敌提示、物资统计去背景要求。

## 证据与实现

- 用户干员表的键是 ExpertId，原实现却传入独立的 HeroID。按 SDK 分开读取：HeroID 使用 CharacterFashionComponent +0x508 / PlayerState +0x9F0；ExpertId 使用 BattleClassComp +0x100 / PlayerState +0x9F8。实时 HeroData 本地化名称优先，ExpertId 的 16 项用户字典作回退。
- SDK 的 PlayerState +0x4C0 是 bFinishGame。人物剔除改为 +0x39E 的观战、仅观战和未激活位；人机识别同时包含 bIsPlayerAI、bIsPlayerAI_SOL、bIsABot。
- 全局类名分类成功后，仍允许已通过角色或拾取物结构检查的未知类进入原有严格读取流程，避免提前跳过结构回退。
- 匹配完整物品 FName 后，缓存配置行分别补缺失的品质、名称、指导价。结构识别的地面物资通过明确入口复用同一读取核心，普通类名读取入口保留原门槛。
- FPS 只绘制描边文字；背敌保留各自箭头和距离。物资统计为红、金、紫、蓝、绿五行，每行显示数量与已读价值合计，无标题、卡片或底色，沿用已有 X/Y 位置和最高 30Hz 重算。

## 验证与限制

本地已通过人物资料、状态和缓存物资解码、血量、标签统计、实际帧率、菜单、雷达与背敌布局回归，以及字体、IPA 权限测试。Objective-C++ 设备编译和 UIKit 绘制断言由本次提交的 GitHub Actions 验证，交付结果记录在 build-delivery 对应版本目录。

用户确认平板当前在训练营且能看到人机。Windows PnP 和 Frida 设备枚举可见 iPad，但 Frida 进程枚举返回 USB I/O Error；usbmux 列表为空，现有本地转发返回 connection closed。因此本批没有取得游戏内的运行时字段，不能把源码修复和合成回归当作对决实机已恢复的证明。

仍待运行证据核对：对决角色的 mesh/骨骼验证、当前 GameItem 表对象、缓存行可用性，以及设备实际呈现效果。
