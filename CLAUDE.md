# AgentStatusBoard — 项目须知（给 Claude Code / Codex 会话）

macOS 菜单栏水球 + 桌面悬浮窗，实时显示 Codex / Claude Code (CC) 的会话状态（进行中 /
需处理 / 已完成）和 5h/周用量**余额**。原生 Swift（SwiftUI + AppKit），Swift Package
Manager，LSUIElement（无 Dock 图标）。以**源码**分发，各自本机编译 + 通过 GitHub 自更新。

当前已发布版本：**v1.23**（每版"为什么"见 `CHANGELOG.md`）。

## 编译 / 运行 / 测试
- `swift build` / `swift test` —— 编译 + 单测（Swift Testing 框架）。
- `./script/build_and_run.sh run` —— debug 编译、组装 `.app` 并启动。
- `./script/build_and_run.sh package` —— release 编译 → `dist/AgentStatusBoard.app`（+ zip）。
- `./script/agent-hooks/autostart.sh on` —— 装到 `~/Applications` + 写 LaunchAgent + kickstart。
  **这是让新构建"生效"的方式**（App 由 launchd 托管、`KeepAlive=false`）。
- **改完代码让本机生效的固定套路**：`build_and_run.sh package` → `autostart.sh on`。

## 架构（事件驱动，非轮询）
Hook 脚本写状态、Swift App 读状态。
- **Hook 脚本 `script/agent-hooks/`**：CC hooks（配在 `~/.claude/settings.json`）、Codex hooks
  （配在 `~/.codex/config.toml`）调用 `record.sh` / `cc-hook.sh` / `codex-hook.sh` /
  `codex-notify.sh`，写 `~/.agent-status-board/sessions/<source>-<id>.json` + 追加
  `activity.jsonl`；`classify.py`（Stop 时后台跑）用 LLM 判"是否需要你输入"+一句话摘要。
- **`Sources/AgentStatusBoard/Services/SessionEventCollector.swift`** —— 核心。读状态文件 +
  实时 transcript，决定每个会话的状态 / 标题 / 过滤。
- `Services/SessionNames.swift` —— 显示名覆盖，读 `~/.agent-status-board/names.json`。
- `Services/UsageCollector.swift` —— Codex 用量（实时 `chatgpt.com/backend-api/wham/usage`）
  + CC 用量（Anthropic 限流响应头）。
- `Stores/BoardStore.swift` —— `@Published` 状态、刷新循环、用量抓取节奏。
- `App/StatusItemController.swift` —— 菜单栏液态玻璃水球（Core Graphics 自绘）。
- `Views/DesktopWidgetView.swift` —— 桌面悬浮窗。

## 关键约定 & 坑（改这些地方前必看）
1. **Hook 跑的是 `~/.agent-status-board/bin/` 里的副本，不是 repo 里的**。改完任何
   `script/agent-hooks/*` 运行时脚本，必须重跑 `install.sh`（或走自更新）推到 bin，否则不生效。
2. **会话名解析顺序**（SessionEventCollector）：`names.json` 会话-ID 置顶 → `names.json` 路径
   置顶 → CC 自带 custom/ai 标题（从 transcript 读）→ 文件夹名。**CC 对没手动改过名的会话不存
   任何短标题**（只有冗长 ai-title + 文件夹名）——短的人类名只能来自 `names.json`。别再靠"换
   一个自动来源"去修错误标题。
3. **"正在执行"以 transcript 为准、不信 hook 记录**。goal / 自动模式自主连跑会停止触发 CC hook、
   事件记录会冻结。`refinedStatus()` 用 transcript 信号：助手回合答完静置 >60s → 完成；tool_use
   挂起 >90s → 需处理（红）。保留 / 老化按 transcript 真实活动时间算，不按（可能冻结的）hook 时间。
4. **定时 / 自动化 Codex 会话会被隐藏**（`codexIsAutomation`）：它们 rollout 的 `session_meta`
   带 `thread_source: "automation"`（交互会话是 `"user"`）。**这是用户特意要的**（不想在看板上
   看到每日 sync/backup 定时任务）——别"修回来"。
5. **用量·Codex**：优先实时 `wham/usage`；抓取偶发失败时**保留上次实时值、不要退回本地 rollout
   快照**（快照数字不一样、偏低）。`wham/usage` ≠ rollout 的 `token_count`，是两个不同指标。
6. 菜单栏水球显示 5h **余量**（100 − used），随消耗 green→amber→red。

## 发版 / 分发
- `VERSION` 文件是**版本单一来源**。App 每小时比对远端 `raw.githubusercontent.com/.../VERSION`
  与本地，远端更高才更新。
- **`./script/release.sh <版本>`** = bump VERSION + commit（`git add -A`）+ 注解 tag + push main
  + push tag + `gh release create`（说明取 CHANGELOG 里对应的 `## v<版本>` 段落——**先写好该段**）。
- **铁律：合并了任何带功能改动的 PR（哪怕只改 hook 脚本）后，必须 bump VERSION 再发版**，否则
  自更新分发不出去、`main` 会领先 tag。
- `main` 受分支保护（PR + 1 审批）。owner（walle0624）可 `gh pr review <N> --approve` 后
  `gh pr merge <N> --squash`。`release.sh` 直推 main（显示 "Bypassed rule violations" 属正常）。
- 审 PR：`./script/review-pr.sh <N>` 拉进隔离 git worktree、编译 + 测试、列 diff。
- 网络：github.com 直推通过本机 FlClash 代理正常工作；别预设"被墙"就绕 API。

## 安全（不可违反）
- 密钥 / token 只放 `~/.agent-status-board/`（chmod 600），**绝不提交进 repo**。repo 是公开的
  （这样别人下 `VERSION` 免 token）。
- 不硬编码 Claude / Anthropic API key；"需要输入"分类器走任意 OpenAI 兼容端点，配在
  `~/.agent-status-board/classify.json`。
- 绝不打印 token。

## 更多细节
- `AI-SETUP.md` —— 安装 / 配置指南（写给 AI 在新机器上执行）。
- `CHANGELOG.md` —— 每版历史（每个修复的"为什么"）。
- `README.md` —— 概览。
