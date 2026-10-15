# HUD 触摸、生命周期与流畅性修复设计

用户授权：修复当前不能正常运行的悬浮 UI，允许调整布局、重构，逐项验证，并分析原版功能差距。四份交接资料仅作历史证据；其中的安装、停止、推送示例不自动执行。

基线：`fix/hud-context-startup` / `9ec2a2ea468b6f40315904b1c225329fbe92f00c`。实际源代码包含 M5.66；最近两次回归失败，最近一次是 simulator launch 超时。Windows 本机没有 Xcode，初次 USB 设备列表为空。

## 已确认的问题

1. 菜单 `_ignoresHitTest` 在设置内容前返回 YES，窗口 context 创建时身份错误。
2. 小球的整个区域同时充当拖动区，生产输入桥提前返回，展开按钮永远收不到点击。
3. 身份连续性兜底在拒绝异指之前刷新位置，能把异指转换成原指；内部 token 与 raw ID 也会碰撞。
4. tab bar 上报范围包含整页，抵消空白区域判定；标题、页签和退出仍随根窗口滚动。
5. “整面板穿透但菜单照常能点”允许同一次物理点击同时作用于两个应用，不作为产品交互。
6. 停止先删 PID 丢失仍在运行的进程；固定通知无会话隔离；两个退出通道都依赖主队列。
7. `nextDrawable` 在主线程等待；事后跳帧无法避免已经发生的阻塞。ImGui 未设置实际 DeltaTime。

## 设计与边界

- 保留独立 HUD、已有可显示的 native context/hosting 顺序和绘制窗固定穿透角色；不改权限和内核链。
- 菜单从分配开始始终是交互窗口。展开时只在可见控件、页签、标题、滚动条和弹出内容接受菜单输入；同一几何策略用于 UIKit 命中和 HID Began。手势从空白/窗外开始不得滑入激活菜单。
- UIKit `hitTest` 是进程内视图命中规则，不等于已证明跨进程空白区域穿透。提供可靠的“收起并穿透”：实际原生窗口从 348×520 缩到 56×56，旧覆盖区恢复可操作；点球展开，拖球只移动，不展开。删除双重响应的整面板模式。
- 固定标题、收起/退出、页签及保存栏；仅内容 child 滚动。控件命中矩形裁剪至可见视口；popup 和 scrollbar 显式覆盖。
- HID 字段通过真实工厂创建已知 identity/index/type 的探针并读回校验，避免直接信任历史头字段；解析失败明确拒绝启动。所有权优先使用经验证的 raw identity，不用距离/时间把不同手指合并；必要字段变化先输出可配对证据。
- 退出请求与 PID 身份记录分离，针对 session；独立控制队列先安排有期限的硬退出，再请求主线程撤窗口。确认死亡后才清理自己的身份。启动失败、超时和正常停止复用同一协议；停止失败仍能找到同一进程并再次停止。
- drawable 获取在有并发上限的独立串行队列，ImGui/UI 构建和输入仍归主线程；GPU 完成归还帧额度，晚到的 drawable 不得让已停止的渲染复活。每个 context 使用实际单调时间步长。
- 去掉颜色拖动中每帧同步保存。绘制空闲策略根据实际生成的图元。

## 验证

先记录旧版本的失败行为，再实施。运行真实 child 生命周期回归、真实 IOKit/生产输入桥、真实 UIKit context 初始化及生产菜单布局回归。云端编译 IPA 并核验 SHA/权限。真机未连接时明确保留“待真机验证”，不把编译通过、PID 存在或首帧完成写成手感已验收。

苹果资料：

- https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:)
- https://developer.apple.com/documentation/uikit/uiview/point(inside:with:)
- https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable()
- https://github.com/Lessica/TrollSpeed/blob/main/sources/HUDMainWindow.mm （开源实现参考，不是苹果公开契约）
