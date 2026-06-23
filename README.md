# Agent Status Board

> 🤖 **如果你是帮用户安装本组件的 AI 助手**：请直接阅读并执行 **[AI-SETUP.md](AI-SETUP.md)**（含编译、hooks、切换 LLM、CC 登录认证的全部命令）。

A macOS menu bar widget that shows what your Codex and Claude Code sessions are
doing right now — styled after [tienflow/CodexBar](https://github.com/tienflow/CodexBar):
a transparent pill with three traffic-light LEDs, plus a richer dropdown.

## States (aggregate across all sessions)

| State | LEDs |
|-------|------|
| idle 空闲 | three dim |
| running 正在执行 | amber/green marquee |
| thinking 思考中 (context compaction) | amber breathing |
| needs confirm 需要确认 | red flashing (2 Hz) |
| done 完成 | green solid |

The menu bar pill is a self-drawn `NSStatusItem` (Core Graphics + a 15 fps timer)
because SwiftUI's `MenuBarExtra` label cannot animate. The dropdown panel shows
per-tool rows, active sessions (model / cwd / last tool), and an **activity
timeline** — the feature CodexBar doesn't have.

## How it knows the state — event driven, not polling

Lifecycle hooks write a small JSON file per session to
`~/.agent-status-board/sessions/` and append to `~/.agent-status-board/activity.jsonl`.
The app reads them every 3 s.

- **Claude Code** hooks (`~/.claude/settings.json`): UserPromptSubmit → running,
  Pre/PostToolUse → last tool, Pre/PostCompact → thinking, Notification →
  needs-confirm, Stop → done, SessionEnd → clear.
- **Codex** `notify` wrapper (`~/.codex/config.toml`): turn ended → done. The
  wrapper passes the event through to the original notify program, and filters
  out Codex's internal ambient agents (memory / suggestions / safety) so they
  don't pollute the board. "Running" is inferred from the latest rollout file's
  mtime (Codex has no turn-started event).

## Install / run

```bash
./script/build_and_run.sh run          # build .app + launch
bash script/agent-hooks/install.sh     # wire hooks into CC + Codex (backs up configs)
bash script/agent-hooks/uninstall.sh   # restore original configs
```

Hooks take effect on the next new Claude Code session / Codex restart.
The app is read-only: it never continues, stops, or mutates any Codex/CC work.

## 发版（维护者）

改完代码后，一条命令完成「改版本号 + 提交 + 打 tag + 推送 + 建 GitHub Release」：

```bash
# 1) 先在 CHANGELOG.md 顶部写好新版段落，例如：
#      ## v1.15
#      - 改了什么…
# 2) 发版（自动把该段落当作 Release 说明）：
bash script/release.sh 1.15        # 指定版本号
bash script/release.sh next        # 自动 +1（1.14 → 1.15）
bash script/release.sh 1.15 -n     # --dry-run 空跑预览，不改任何东西
```

版本号即 `VERSION` 文件。推送后，所有装了本组件的人会在下次检查（每小时）或
重启时收到「有新版本 · 点击更新」提示。更新源由 `update-source.json` 指定。
