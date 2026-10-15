# AgentStatusBoard — 项目须知（给 Claude Code / Codex 会话）

macOS 菜单栏水球 + 桌面悬浮窗，实时显示 Codex / Claude Code (CC) 的会话状态（进行中 /
需处理 / 已完成）和 5h/周用量**余额**。原生 Swift（SwiftUI + AppKit），Swift Package
Manager，LSUIElement（无 Dock 图标）。以**源码**分发，各自本机编译 + 通过 GitHub 自更新。

当前已发布版本：**v1.33**（每版"为什么"见 `CHANGELOG.md`）。

> **维护须知**：这份文件是本项目的"活文档"，会话进入此文件夹会自动加载它。凡是改动了
> 编译 / 发版流程、关键约定或踩坑经验（包括上面的版本号），都要顺手同步更新这份 `CLAUDE.md`，
> 别让它跟代码漂移。

## 编译 / 运行 / 测试
- `swift build` / `swift test` —— 编译 + 单测（Swift Testing 框架）。
- `./script/build_and_run.sh run` —— debug 编译、组装 `.app` 并启动。
- `./script/build_and_run.sh package` —— release 编译 → `dist/AgentStatusBoard.app`（+ zip）。
  组装完 bundle 后会 **ad-hoc 签名**（`codesign --force --deep --sign -`），见坑 7。
- `./script/agent-hooks/autostart.sh on` —— 装到 `~/Applications` + 写 LaunchAgent + kickstart，
  然后 **pgrep 轮询确认真的起来了**，没起来就自动 bootout + 重新 bootstrap，最后 `open` 兜底。
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
- `Views/StatusViews.swift` —— 状态视觉件（玻璃 LED 等）。

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
4. **定时 / 自动化 Codex 会话会被隐藏**（`codexIsHidden`）：它们 rollout 的 `session_meta`
   带 `thread_source: "automation"`（交互会话是 `"user"`）。**这是用户特意要的**（不想在看板上
   看到每日 sync/backup 定时任务）——别"修回来"。**CC 侧同理**：launchd 定时任务用 `claude -p`
   起的无头会话，继承 launchd 的工作目录 `/`（交互会话永远在某个项目目录里），记录 cwd 为
   `"/"` 的会被 `ccIsHidden` 隐藏——同样是用户特意要的，别"修回来"。规则**故意只认 `/` 这一条**，
   其它路径（含空 cwd）一律 fail-open 照常显示，绝不误隐真实会话。
5. **用量·Codex**：优先实时 `wham/usage`；抓取偶发失败时**保留上次实时值、不要退回本地 rollout
   快照**（快照数字不一样、偏低）。`wham/usage` ≠ rollout 的 `token_count`，是两个不同指标。
6. 菜单栏水球显示 5h **余量**（100 − used），随消耗 green→amber→red。
7. **原地升级必须签名**（自更新命脉）。Swift 链接器只给 binary 一个 linker-signed 签名，
   Info.plist 没绑、resources 没封印。**全新安装能跑，但同一路径整包替换后下一次启动会被
   macOS 打死**：`SIGKILL (Code Signature Invalid)` / CODESIGNING `Launch Constraint Violation`，
   接着 launchd 卡在 `job state = spawn failed`、`last exit code = 78 (EX_CONFIG)`——而
   `launchctl kickstart` 仍然返回 0，看起来"成功了"。所以：
   (a) `build_and_run.sh` 组装完 bundle **最后一步**做 ad-hoc 签名（之后不准再改动 bundle）；
   (b) **绝不给"已安装 + 已注册"的副本补签**——补签会让它和 launchd/BTM 注册对不上，
   变成每次 spawn 都 EX_CONFIG（踩过，只能 bootout 重注册才能救回来）；
   (c) `autostart.sh` 起完必须 pgrep 确认，没起来就 bootout + 重新 bootstrap。
   **但 bootout 会杀光该 job 里的所有进程，自更新时这个脚本自己就在里面**（App 用
   `nohup bash /tmp/asb-update.sh &` 拉起，继承了 `XPC_SERVICE_NAME=<label>`）——所以脚本靠
   `XPC_SERVICE_NAME != $LABEL` 判断"不是自更新上下文"才敢 bootout，自更新场景退到 `open` 兜底。
8. **改 `~/.codex/config.toml` 必须按 TOML 结构读、只追加缺失项**（`script/agent-hooks/codex_toml.py`）。
   Codex 保存时会把字符串改成双引号、丢掉注释（包括我们的 `# >>> agent-status-board hooks >>>` 标记）；
   Computer Use 会把 `notify` 改成多行数组，用 `--previous-notify '["\/…\/codex-notify.sh"]'` 串上我们。
   逐行正则认不出这些，曾插出第二个 `notify`、复制整段表 → `duplicate key`，Codex 起不来（2026-10-15）。
   所以：已接入（与引号/标记无关；notify 值里任何位置有 `codex-notify.sh` 就算，**绝不替换**，否则
   codex-notify.sh ↔ Computer Use 死循环）就一字不改；缺什么只追加什么，不删不搬（`[hooks.state]`
   信任按位置记）；配置已不合法就不碰。改安装 / 卸载脚本后跑 `python3 script/tests/test_codex_config.py`。
9. **自更新绝不覆盖 git 检出的源码**（`script/update.sh`）。App 拿远端 `VERSION` 比的是**正在运行的
   bundle 版本**，不看检出目录，所以发版、或装回旧的 `dist/` 构建，都会让本机 App 自更新；开发机上
   `update.json` 的 `checkout` 就是本 repo。旧版末尾 `rsync -a --delete` 把下载的 main 整个盖上来：
   2026-10-15 发 v1.32 后，未提交改动、未跟踪和被忽略的文件（新测试、`PROJECT_MEMORY.md`）全被抹掉。
   现在检出是 git 工作树（或含 `.git`）就跳过源码刷新（源码用 git 自己更新），照常重装 App、刷新 bin
   副本；zip 安装照旧整目录刷新。改 `update.sh` 后跑 `python3 script/tests/test_self_update.py`。

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
