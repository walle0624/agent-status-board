# 视觉重设计任务:Agent Status Board 桌面悬浮窗

你是一位资深视觉设计师 + SwiftUI 工程师。请对本仓库的 macOS 桌面悬浮窗做一次**整体审美升级**,
目标是达到下面两个参考站的质感水平。先读 `CLAUDE.md` 了解项目;改完必须 `swift build` 通过、
`swift test` 全绿。

## 参考视觉语言(务必吃透后再动手)

**参考 1:Border Beam(beam.jakubantalik.com)**
- 深色玻璃卡片,一段柔和的渐变光束(暖橙 → 品红 → 紫)沿圆角边框缓慢游走(Rotate 模式),
  光晕会向卡片内侧自然渗透(bloom),另有 Pulse(整圈呼吸)模式。
- 质感关键:光束是"一段有长度、两端淡出的光",不是整圈描边;运动平滑匀速;亮度克制。

**参考 2:Thinking Orbs(orbs.jakubantalik.com)**
- 由几十个细小白点组成的 3D 点阵粒子球(经纬分布),不同状态有不同的运动:
  Working(稳定自转)/ Searching(散开搜寻)/ Solving(聚拢收敛)/ Listening(轻微脉动)/
  Breathing(整体呼吸)/ Shaping(形变)等,共 9 种;有 64px 和 20px 两档尺寸;速度可调。
- 质感关键:单色白点、透视产生的近大远小/近亮远暗、极简克制,像"会思考的小生命体"。

## 映射到本项目(设计要求)

1. **窗口边界光束**(参考 1 → `DesktopWidgetView` 卡片边框):
   - 有会话「需要处理」(红)时:红色系光束沿窗口圆角边框游走,提示最强;
   - 只有「正在执行」(黄)时:琥珀色系光束,克制一些;
   - 全部空闲/完成时:无光束或极淡的一次 Pulse。
   - 光束颜色可以从现有 `Glass.red / Glass.amber` 出发做渐变,但允许你调出更高级的配色。

2. **会话行的状态指示 → 迷你思考球**(参考 2 的 20px 档,替换现在的 `LEDDot` 玻璃球):
   - 正在执行(running)→ Working 式稳定自转;
   - 思考中(thinking)→ Breathing 式呼吸;
   - 需要处理(waitingReview)→ 更急促的红色系脉动(Listening 加速版);
   - 已完成(done)→ 粒子静止、聚成安定的小球,亮度调低。
   - 粒子数、半径、透视、速度这些参数你自己定,以"顺滑 + 高级"为准。

3. **整体氛围**:保持现有深色液态玻璃基调,但你可以重调:卡片底色渐变、四角氛围光、
   分区标题排印、行 hover 效果,向参考站的"黑得纯粹、亮得克制"靠拢。

## 硬约束(不可违反)

- 纯 SwiftUI/AppKit + Core Graphics,**不引入任何第三方依赖**;动画建议用
  `TimelineView(.animation)` / `Canvas`(悬浮窗)——注意窗口是常驻的,CPU 要克制
  (空闲状态应几乎不耗 CPU;可在无动效需求时停掉 Timeline)。
- **只做视觉层**:`Views/DesktopWidgetView.swift`、`Views/StatusViews.swift` 随你重构;
  但 `Stores/`、`Services/`、`App/FloatingWidgetController.swift` 的数据流、点击打开会话、
  三段布局逻辑(需要处理/正在执行/最近完成的自适应规则)、用量「余量」条,行为一律不变。
- 菜单栏水球(`App/StatusItemController.swift`)这次**不动**。
- 状态语义(红=需要处理 / 黄=正在执行 / 绿=完成)不变,色相可微调但用户一眼要能对上。
- `NSHostingView` 背景透明、窗口投影等既有坑见 `CLAUDE.md`,别回退。
- 弹出面板复用同一视图(`inPopover: true`),你的改动要在两种宿主下都正常。

## 交付

- 直接改代码;`swift build` 通过、`swift test` 全绿后,写一份 `KIMI_NOTES.md`
  (改了什么、设计决策、参数在哪调)。不要 git commit,保持工作区改动即可。
