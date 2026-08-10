# KIMI_NOTES — 视觉重设计（Border Beam + Thinking Orbs）

按 `DESIGN_BRIEF.md` 完成悬浮窗整体审美升级。只动了视觉层两个文件：

- `Sources/AgentStatusBoard/Views/StatusViews.swift` —— 新增 `ThinkingOrb`
- `Sources/AgentStatusBoard/Views/DesktopWidgetView.swift` —— 新增 `BorderBeam` / `PulseBeam`，
  重调背景氛围、会话行指示器、分区标题排印、hover

数据流、点击打开会话、三段自适应布局、用量条行为一律未改；`StatusItemController.swift`（菜单栏水球）未动。
`swift build` 通过、`swift test` 11/11 全绿。未做 git commit。

## 改了什么

### 1. 窗口边界光束（参考 Border Beam）

- 新组件 `BorderBeam`（DesktopWidgetView.swift 底部，private）：
  - **Rotate**：一段有长度、两端淡出的渐变光（AngularGradient 通过 `startAngle/endAngle`
    同步 +θ 实现整圈匀速旋转，光束段约占周长 1/3）。光晕渗透做法：同一描边画两份——
    一份 1.2px 清晰核心线，一份 12px 加 `blur(6)` 并用圆角矩形 mask 裁进卡片内侧（bloom）。
  - **PulseOnce**：`PulseBeam`，进入平静态时一次性呼吸（0.9s easeIn 到 0.30 → 1.6s easeOut
    收在 0.06 的极淡余迹），无 TimelineView，播完零 CPU。
- 状态映射（`DesktopWidgetView.beamStyle / beamColors`）：
  - 有「需要处理」→ 红色系旋转光束：`#FF7A45 → #FF2E63 → #B04CFF`（暖橙→品红→紫红移版，
    保留"红=需要你"的一眼语义）；
  - 只有「正在执行」→ 琥珀色系：`#FFD15E → #FF9F3E → #FF734D`，整体更暗更克制；
  - 全空闲/完成 → 一次薄荷绿系 Pulse 后归于平静。

### 2. 会话行状态指示 → 迷你思考球（参考 Thinking Orbs 20px 档）

- 新组件 `ThinkingOrb`（StatusViews.swift，internal，可复用）：
  - 46 个点的经纬点阵球（6 条纬线 4/8/10/10/8/4 + 两极），Canvas 自绘；
  - 3D：绕 Y 自转 + 固定 0.45rad 倾角，透视除法（相机距离 2.9R），近大远小、近亮远暗，
    远侧先画近侧后画；
  - 点色 = 状态色向白混 68%（`NSColor.blended`），保持"白点粒子"的克制感，同时
    红/黄/绿语义一眼可辨；底部再叠一层状态色 halo。
- 状态映射（`DesktopWidgetView.statusOrb`）：
  - `running` → `.working`：稳定自转，一圈 5.5s；
  - `thinking` → `.breathing`：慢转（14s/圈）+ 半径 ±11%、亮度 3.8s 呼吸；
  - `waitingReview/blocked/failed/stale` → `.pulsing`：0.85s 急促脉动（smoothstep 削尖波峰）
    + 2.6s 快转 + 每点 ±10% 散射抖动；
  - `done` → `.settled`：粒子收拢到 0.58R、亮度压到 0.55，中心叠一个致密核，**完全静态、
    不起 TimelineView**。

### 3. 整体氛围

- 卡片底色调黑：`#0E111A@0.80 → #04050A@0.92`（原来偏蓝灰），"黑得纯粹、亮得克制"；
- 四角氛围光跟随状态换色相（`moodGlows`）：红态 = 红+紫，执行态 = 琥珀+蓝，平静态 = 蓝+紫；
- 分区标题（正在执行 / 最近完成 / 余量）改为 10pt semibold + tracking 1.1 的小标题排印；
- 行 hover 描边由 0.07 → 0.12、底色 0.08 → 0.085，反馈更清晰但仍克制。

## CPU 约束

- 所有动画走 `TimelineView(.animation(minimumInterval: 1/30))`（约 30fps 节流）；
- 空闲/全完成时：**没有任何活跃 TimelineView**——光束停（只剩一次性 Pulse）、done 行是静态
  Canvas、header 玻璃球不闪。常驻窗口空闲几乎零耗；
- 弹出面板（`inPopover: true`）复用同一视图，两种宿主均已覆盖。

## 参数在哪调

| 想调什么 | 位置 |
|---|---|
| 光束速度 | `BorderBeam.period`（默认 7.5s/圈） |
| 光束长度/淡出 | `BorderBeam.beam(phase:)` 里的 gradient stops（0.25–0.59 区间） |
| 光束配色 | `DesktopWidgetView.beamColors` |
| 光晕渗透强度 | bloom 层 `lineWidth: 12` / `blur(6)` / `opacity(0.45)` |
| Pulse 幅度/节奏 | `PulseBeam` 的 0.30 / 0.06 / 两个 duration |
| 球粒子数/经纬分布 | `ThinkingOrb.rings` |
| 透视强弱 | `ThinkingOrb.perspective`（2.9，越小透视越夸张）、`tilt`（0.45） |
| 各状态速度/振幅 | `ThinkingOrb.dynamics(t:)` 与 `spinPeriod` |
| 点大小 | `canvas` 里 `size * 0.055` |
| 点色白度 | `tint` 里 `blended(withFraction: 0.68, of: .white)` |
| 氛围光/底色 | `DesktopWidgetView` 的 `.background` ZStack 与 `moodGlows` |

已用离屏 NSHostingView 渲染验证过光束各相位与思考球四种模式的实际观感（近大远小、
两端淡出、内渗 bloom 均成立）。
