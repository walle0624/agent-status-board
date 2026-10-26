#!/usr/bin/env bash
# autostart.sh [on|off|install] — install and start, disable, or install for lldb.
# Installs the built app to ~/Applications and a LaunchAgent that starts it.
set -euo pipefail

LABEL="com.linkingdigital.agentstatusboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DST="$HOME/Applications/AgentStatusBoard.app"
BIN="$APP_DST/Contents/MacOS/AgentStatusBoard"

MODE="${1:-on}"
case "$MODE" in
  off)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "autostart disabled (app left in ~/Applications; rm -rf to remove)."
    exit 0
    ;;
  on|install) ;;
  *) echo "usage: $0 [on|off|install]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_SRC="$ROOT_DIR/.build/packaging/AgentStatusBoard.app"
[ -d "$APP_SRC" ] || { echo "build first: ./script/build_and_run.sh package" >&2; exit 1; }

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
UID_="$(id -u)"
DOMAIN="gui/$UID_"
INSTALL_TMP="$(mktemp -d "$HOME/Applications/.asb-install.XXXXXX")"
REPLACED=0
HAD_OLD=0

# A process name alone could be a legacy dist/Downloads copy. Only the stable
# installed executable counts as a successful launch.
app_is_running() {
  local pid running_path
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    running_path="$(ps -p "$pid" -o comm= 2>/dev/null)" || continue
    [ "$running_path" = "$BIN" ] && return 0
  done < <(pgrep -x AgentStatusBoard 2>/dev/null || true)
  return 1
}

wait_for_app() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    app_is_running && return 0
    sleep 0.5
  done
  return 1
}

finish_install() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -ne 0 ] && [ "$REPLACED" = 1 ] && [ "$HAD_OLD" = 1 ]; then
    echo "installation failed — restoring the previous app." >&2
    pkill -x AgentStatusBoard >/dev/null 2>&1 || true
    rm -rf "$APP_DST"
    if ! mv "$INSTALL_TMP/previous.app" "$APP_DST"; then
      echo "rollback failed; previous bundle preserved at $INSTALL_TMP/previous.app" >&2
      exit "$rc"
    fi
    # The launchd registration may now refer to the failed replacement's
    # signature. Re-register the restored bundle unless doing so would kill
    # this legacy updater's own job; that case uses LaunchServices instead.
    if [ "${XPC_SERVICE_NAME:-}" != "$LABEL" ]; then
      launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
      launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 || launchctl load "$PLIST" >/dev/null 2>&1 || true
    else
      open "$APP_DST" >/dev/null 2>&1 || true
    fi
    if ! wait_for_app; then
      open "$APP_DST" >/dev/null 2>&1 || true
      wait_for_app || echo "rollback: previous app restored at $APP_DST but failed to start." >&2
    fi
  fi
  rm -rf "$INSTALL_TMP"
  exit "$rc"
}
trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Prepare the entire replacement before stopping the working app. A copy or
# validation failure leaves the installed bundle and running process untouched.
cp -R "$APP_SRC" "$INSTALL_TMP/AgentStatusBoard.app"
python3 - "$INSTALL_TMP/AgentStatusBoard.app" <<'PY'
import os, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
data = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if data.get("CFBundleIdentifier") != "ai.linkingdigital.AgentStatusBoard" or not os.access(app / "Contents/MacOS/AgentStatusBoard", os.X_OK):
    sys.exit("invalid AgentStatusBoard build; installed app left untouched")
PY

cleanup_legacy_bundle() {
  python3 - "$1" <<'PY'
import pathlib, plistlib, shutil, sys
root = pathlib.Path(sys.argv[1])
legacy = root / "dist" / "AgentStatusBoard.app"
# Only this exact legacy product is eligible, never its parent or any zip.
if legacy.is_symlink() or legacy.parent.is_symlink() or not legacy.is_dir():
    sys.exit(0)
info = legacy / "Contents/Info.plist"
try:
    if info.is_symlink() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != "ai.linkingdigital.AgentStatusBoard":
        sys.exit(0)
except (OSError, ValueError, plistlib.InvalidFileException):
    sys.exit(0)
shutil.rmtree(legacy)
print("removed obsolete build: " + str(legacy))
PY
}

cleanup_legacy_bundles() {
  cleanup_legacy_bundle "$ROOT_DIR"
  if [ -n "${ASB_LEGACY_CHECKOUT_DIR:-}" ] && [ "$ASB_LEGACY_CHECKOUT_DIR" != "$ROOT_DIR" ]; then
    cleanup_legacy_bundle "$ASB_LEGACY_CHECKOUT_DIR"
  fi
}

# Stop copies only after the replacement is ready. Current updaters run in an
# independent job; keep the later same-job guard for older installed launchers.
pkill -x AgentStatusBoard >/dev/null 2>&1 || true
if [ -e "$APP_DST" ] || [ -L "$APP_DST" ]; then
  mv "$APP_DST" "$INSTALL_TMP/previous.app"
  HAD_OLD=1
fi
REPLACED=1
mv "$INSTALL_TMP/AgentStatusBoard.app" "$APP_DST"

python3 - "$PLIST" "$LABEL" "$BIN" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as out:
    plistlib.dump({"Label": sys.argv[2], "ProgramArguments": [sys.argv[3]],
                  "RunAtLoad": True, "KeepAlive": False,
                  "ProcessType": "Interactive", "LSUIElement": True}, out)
PY

if [ "$MODE" = install ]; then
  cleanup_legacy_bundles
  echo "App installed at $APP_DST (start with lldb)."
  exit 0
fi

# launchctl reports success even when the spawn afterwards fails — a job left
# registered against a replaced bundle keeps returning 0 while every start dies
# ("job state = spawn failed", last exit 78/EX_CONFIG). So the only signal worth
# trusting is the stable installed executable: poll for it, ~5s.

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
  if ! app_is_running; then
    echo "still not up — falling back to open(1)."
    open "$APP_DST" >/dev/null 2>&1 || true
    wait_for_app || {
      echo "autostart: app failed to start. Inspect: launchctl print $DOMAIN/$LABEL" >&2
      exit 1
    }
  fi
fi
cleanup_legacy_bundles
echo "autostart enabled. App installed at $APP_DST and started."
