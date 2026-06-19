#!/usr/bin/env bash
# autostart.sh [on|off]  — enable/disable launch at login.
# Installs the built app to ~/Applications and a LaunchAgent that starts it.
set -euo pipefail

LABEL="com.linkingdigital.agentstatusboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DST="$HOME/Applications/AgentStatusBoard.app"
BIN="$APP_DST/Contents/MacOS/AgentStatusBoard"

case "${1:-on}" in
  off)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "autostart disabled (app left in ~/Applications; rm -rf to remove)."
    exit 0
    ;;
  on) ;;
  *) echo "usage: $0 [on|off]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_SRC="$ROOT_DIR/dist/AgentStatusBoard.app"
[ -d "$APP_SRC" ] || { echo "build first: ./script/build_and_run.sh run" >&2; exit 1; }

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
# Stop any running copy, then install the latest build to a stable location.
launchctl unload "$PLIST" 2>/dev/null || true
pkill -x AgentStatusBoard >/dev/null 2>&1 || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

launchctl load "$PLIST"
echo "autostart enabled. App installed at $APP_DST and started."
