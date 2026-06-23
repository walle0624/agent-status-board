#!/usr/bin/env bash
# cc-token-setup.sh — generate a long-lived Claude token for the CC usage panel.
#
# Runs `claude setup-token` inside a wide PTY (so the long token isn't wrapped /
# truncated by an 80-column terminal) and saves it to
# ~/.agent-status-board/cc-token.json (chmod 600). Re-run anytime to refresh.
#
# The widget pings /v1/messages (max_tokens:1, negligible) and reads the
# `anthropic-ratelimit-unified-*` headers for the 5-hour and weekly usage.
set -euo pipefail

BASE="$HOME/.agent-status-board"
mkdir -p "$BASE"

# Locate a claude binary: PATH first, then the desktop app's bundled CLI.
CLAUDE="$(command -v claude || true)"
if [ -z "$CLAUDE" ]; then
  CLAUDE="$(ls "$HOME/Library/Application Support/Claude/claude-code/"*/claude.app/Contents/MacOS/claude 2>/dev/null | tail -1 || true)"
fi
if [ -z "$CLAUDE" ] || [ ! -x "$CLAUDE" ]; then
  echo "找不到 claude 可执行文件。请先安装 Claude Code（桌面端或独立 CLI）。" >&2
  exit 1
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

echo "运行 claude setup-token（浏览器会弹出授权，需要 Claude 订阅）…"
python3 - "$CLAUDE" "$LOG" <<'PY'
import os, pty, sys, struct, fcntl, termios
claude, log = sys.argv[1], sys.argv[2]
fdlog = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "4000"
    os.environ["LINES"] = "50"
    os.execv(claude, [claude, "setup-token"])
else:
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 4000, 0, 0))
    except Exception:
        pass
    while True:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        os.write(fdlog, d)
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
PY

TOKEN="$(grep -aoE 'sk-ant-oat[A-Za-z0-9_.-]+' "$LOG" | head -1)"
if [ -n "$TOKEN" ] && [ ${#TOKEN} -gt 60 ]; then
  printf '{"token":"%s"}\n' "$TOKEN" > "$BASE/cc-token.json"
  chmod 600 "$BASE/cc-token.json"
  echo "✅ 已保存 token 到 $BASE/cc-token.json（长度 ${#TOKEN}）。组件几秒后会显示 CC 用量。"
else
  echo "⚠️ 未能从输出提取到 token（可能未完成授权或被中断）。可重试本脚本。" >&2
  exit 1
fi
