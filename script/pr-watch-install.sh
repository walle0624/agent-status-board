#!/usr/bin/env bash
# pr-watch-install.sh [on|off]
#
# Enable/disable a background LaunchAgent that polls for new pull requests every
# 30 minutes and pops a macOS notification for each new one. Lightweight: it only
# notifies — the actual review stays on-demand (script/review-pr.sh).
set -euo pipefail

LABEL="com.linkingdigital.asb-prwatch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/.agent-status-board/bin/pr-watch.sh"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-watch.sh"

case "${1:-on}" in
  off)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "PR 监视已关闭（脚本与已看列表保留）。"
    exit 0 ;;
  on) ;;
  *) echo "usage: $0 [on|off]" >&2; exit 2 ;;
esac

mkdir -p "$HOME/.agent-status-board/bin" "$HOME/Library/LaunchAgents"
cp "$SRC" "$BIN"; chmod +x "$BIN"

launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$BIN</string></array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF

launchctl load "$PLIST"
"$BIN" --test   # one confirmation notification so you know it works
echo "✅ PR 监视已开启：每 30 分钟查一次，新 PR 弹 macOS 通知。关闭：$0 off"
