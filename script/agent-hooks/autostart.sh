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
UID_="$(id -u)"
DOMAIN="gui/$UID_"

# Stop the running copy WITHOUT tearing down the launchd job. During a
# self-update this script runs as a detached descendant of the app's OWN launchd
# job; `launchctl unload`/`bootout` here can take the updater down with the job,
# and a legacy `launchctl load` from that context reloads the app into the wrong
# (dying) bootstrap domain so it never actually appears. pkill only hits the app
# binary, not the bash updater.
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

# launchctl reports success even when the spawn afterwards fails — a job left
# registered against a replaced bundle keeps returning 0 while every start dies
# ("job state = spawn failed", last exit 78/EX_CONFIG). So the only signal worth
# trusting is the process itself: poll for it, ~5s.
wait_for_app() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x AgentStatusBoard >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# Start the freshly-installed app in the user's GUI session. Target gui/<uid>
# explicitly so it works even when called from a launchd-spawned updater: if the
# agent is already registered (the self-update case) restart its instance with
# the new binary; otherwise register it (RunAtLoad starts it).
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
else
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
fi

if ! wait_for_app; then
  # The job is registered but its spawns are dying. A full bootout + bootstrap
  # re-registers it against the new bundle. BUT bootout kills every process in
  # the job — and during a self-update THIS SCRIPT is one of them (the app
  # spawns the updater, which inherits XPC_SERVICE_NAME=$LABEL). So only reset
  # when we are not running inside the job; the updater falls through to `open`
  # and the registration heals on the next login / manual `autostart.sh on`.
  if [ "${XPC_SERVICE_NAME:-}" != "$LABEL" ]; then
    echo "app did not come up — re-registering the launchd job…"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    wait_for_app || true
  fi
  # Last resort: `open` always launches into the GUI session (unmanaged, but the
  # user gets the new version now; launchd picks it up again at next login).
  if ! pgrep -x AgentStatusBoard >/dev/null 2>&1; then
    echo "still not up — falling back to open(1)."
    open "$APP_DST" >/dev/null 2>&1 || true
    wait_for_app || {
      echo "autostart: app failed to start. Inspect: launchctl print $DOMAIN/$LABEL" >&2
      exit 1
    }
  fi
fi
echo "autostart enabled. App installed at $APP_DST and started."
