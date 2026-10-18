#!/bin/bash
# EightCount — one-command setup on your Mac.
#
#   ./setup-mac.sh             generate the Xcode project, compile check, open Xcode
#   ./setup-mac.sh --install   ...and build, sign, install and launch on your
#                              iPhone (cable, or Wi-Fi once paired; iPhone unlocked)
#   ./setup-mac.sh --update    download the newest version from GitHub, then install
#                              it on the iPhone (over Wi-Fi works too)
#   ./setup-mac.sh --shortcut  put a double-clickable "Update EightCount" on your Desktop
#   ./setup-mac.sh --auto-refresh      let the Mac refresh/update the app by itself in
#                                      the background (about once a day, over Wi-Fi)
#   ./setup-mac.sh --auto-refresh-off  switch that off again
#
# Options:
#   --team ABCDE12345          your Apple Team ID (found automatically if possible)
#   --bundle-id com.you.app    use your own bundle ID (if Xcode says the default is taken)
#   --no-open                  don't open Xcode at the end
#
# Things only you can do (the script tells you when they're missing):
#   1. Xcode → Settings → Accounts → + → sign in with your Apple ID (one time)
#   2. iPhone: tap "Trust" when connected, turn on Settings → Privacy & Security
#      → Developer Mode (one time, needs a restart)
#   3. Free Apple ID: after the first install, iPhone Settings → General →
#      VPN & Device Management → your Apple ID → Trust (one time)
set -euo pipefail
cd "$(dirname "$0")"
# Kept so the script can restart itself after downloading a newer version of itself.
ORIG_ARGS=("$@")
SCRIPT_SUM=$(shasum setup-mac.sh 2>/dev/null || echo "")

INSTALL=0; OPEN=1; UPDATE=0; REFRESH=0; TEAM_ID=""; BUNDLE_ID=""
AGENT_LABEL="io.github.splatfire.eightcount.refresh"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
REFRESH_LOG="$HOME/Library/Logs/EightCount-refresh.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --update) UPDATE=1; INSTALL=1; OPEN=0 ;;
    # Used by the background job (see --auto-refresh): quiet, no Xcode window,
    # skips the extra compile check, and only acts about once a day.
    --refresh) REFRESH=1; UPDATE=1; INSTALL=1; OPEN=0 ;;
    --auto-refresh)
      mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
      cat > "$AGENT_PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(pwd)/setup-mac.sh</string>
    <string>--refresh</string>
  </array>
  <!-- Try every 3 hours (and when you log in). The script itself only does
       the real work about once a day, when your iPhone is reachable. -->
  <key>StartInterval</key><integer>10800</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$REFRESH_LOG</string>
  <key>StandardErrorPath</key><string>$REFRESH_LOG</string>
</dict>
</plist>
PL
      launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
      echo "✓ Auto-refresh is on."
      echo "  Your Mac now refreshes EightCount (and installs my updates) about once a day,"
      echo "  whenever it's awake and your iPhone is on the same Wi-Fi and unlocked."
      echo "  You get a notification if something needs you. Log: $REFRESH_LOG"
      echo "  Switch off: ./setup-mac.sh --auto-refresh-off"
      exit 0 ;;
    --auto-refresh-off)
      launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
      rm -f "$AGENT_PLIST"
      echo "Auto-refresh is off."
      exit 0 ;;
    --shortcut)
      SHORTCUT="$HOME/Desktop/Update EightCount.command"
      cat > "$SHORTCUT" <<SH
#!/bin/bash
# Double-click to download the newest EightCount and install it on your iPhone.
"$(pwd)/setup-mac.sh" --update
echo
read -r -p "Done — press Return to close this window. "
SH
      chmod +x "$SHORTCUT"
      echo "Created: $SHORTCUT"
      echo "Double-click it whenever you want the newest version on your iPhone."
      exit 0 ;;
    --no-open) OPEN=0 ;;
    --team) TEAM_ID="${2:-}"; shift ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) # old style: ./setup-mac.sh TEAMID [BUNDLE_ID]
       if [ -z "$TEAM_ID" ]; then TEAM_ID="$1"; else BUNDLE_ID="$1"; fi ;;
  esac
  shift
done

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$1"; }
# A macOS notification — only for the background refresh (you're not watching it).
notify() {
  [ "$REFRESH" = 1 ] || return 0
  osascript -e "display notification \"$1\" with title \"EightCount\"" >/dev/null 2>&1 || true
}
fail() {
  printf '\n\033[1;31m✗ %s\033[0m\n' "$1"
  notify "Auto-refresh needs you: $(printf '%s' "$1" | head -1 | tr -d '"')"
  exit 1
}

# Background-refresh bookkeeping: when it last worked and when the app's
# 7-day signature runs out (seconds since 1970).
STATE_FILE=".refresh-state"
LAST_OK=0; EXPIRES=0
# shellcheck source=/dev/null
[ -f "$STATE_FILE" ] && . "./$STATE_FILE"
NOW=$(date +%s)
if [ "$REFRESH" = 1 ]; then
  echo; echo "=== $(date) — background refresh"
  # Did it already work in the last 20 hours, with more than 3 days left? Then rest.
  if [ $((NOW - LAST_OK)) -lt $((20 * 3600)) ] && [ $((EXPIRES - NOW)) -gt $((3 * 86400)) ]; then
    echo "Refreshed recently (valid until $(date -r "$EXPIRES")), nothing to do."
    exit 0
  fi
fi
# Not able to refresh right now (iPhone away/locked): fine, try again later —
# but warn when the app is about to stop opening.
soft_stop() {
  echo "$1"
  if [ "$REFRESH" = 1 ]; then
    if [ "$EXPIRES" -gt 0 ] && [ $((EXPIRES - NOW)) -lt $((2 * 86400)) ]; then
      notify "EightCount stops opening on $(date -r "$EXPIRES" '+%a %H:%M'). Unlock your iPhone near the Mac (same Wi-Fi)."
    fi
    exit 0
  fi
  fail "$1"
}

# Your personal settings (Team ID, bundle ID) live in this file, not in
# project.yml, so downloading updates never clashes with your changes.
LOCAL_SETTINGS=".eightcount-local"
# shellcheck source=/dev/null
[ -f "$LOCAL_SETTINGS" ] && . "./$LOCAL_SETTINGS"
SAVED_TEAM="${SAVED_TEAM:-}"; SAVED_BUNDLE="${SAVED_BUNDLE:-}"
save_settings() {
  printf 'SAVED_TEAM="%s"\nSAVED_BUNDLE="%s"\n' "$SAVED_TEAM" "$SAVED_BUNDLE" > "$LOCAL_SETTINGS"
}

# Older versions of this script wrote the Team ID into project.yml. Move it
# to the settings file and undo that local edit (otherwise `git pull` fails).
OLD_TEAM=$(sed -nE 's/.*DEVELOPMENT_TEAM: "([A-Z0-9]{10})".*/\1/p' project.yml | head -1)
if [ -n "$OLD_TEAM" ]; then
  SAVED_TEAM="${SAVED_TEAM:-$OLD_TEAM}"
  save_settings
  git checkout -- project.yml 2>/dev/null || true
fi

# A download can clash with a local change to an app file (Xcode sometimes
# rewrites files when the project is opened). git then leaves "<<<<<<<"
# markers in the file and the build breaks. Put back the downloaded version;
# the local change stays saved in `git stash list`.
fix_half_updated_files() {
  local files
  files=$(git -C .. diff --name-only --diff-filter=U 2>/dev/null || true)
  [ -n "$files" ] || return 0
  echo "These files were left half-updated by a download; using the downloaded version:"
  echo "$files" | sed 's/^/  /'
  echo "$files" | while IFS= read -r f; do
    [ -n "$f" ] && git -C .. checkout HEAD -- "$f" 2>/dev/null || true
  done
  git -C .. reset -q 2>/dev/null || true
  echo "(Any local edits to them are kept: see 'git stash list'.)"
}

OLD_HEAD=${EIGHTCOUNT_OLD_HEAD:-$(git -C .. rev-parse HEAD 2>/dev/null || echo "")}
if [ "$UPDATE" = 1 ]; then
  step "Downloading the newest version"
  fix_half_updated_files
  if ! git -C .. pull --autostash --ff-only; then
    # Offline or similar: the background refresh still renews the current version.
    [ "$REFRESH" = 1 ] || fail "Couldn't download the update (see the message above)."
    echo "Couldn't download updates right now — refreshing the current version."
  fi
  fix_half_updated_files
fi
NEW_HEAD=$(git -C .. rev-parse HEAD 2>/dev/null || echo "")
# The download changed this script itself: finish with the NEW version
# (bash would otherwise keep running the old one, with old settings).
if [ -z "${EIGHTCOUNT_REEXEC:-}" ] && [ "$(shasum setup-mac.sh 2>/dev/null || echo "")" != "$SCRIPT_SUM" ]; then
  echo "This setup script was updated too — restarting it."
  export EIGHTCOUNT_REEXEC=1 EIGHTCOUNT_OLD_HEAD="$OLD_HEAD"
  exec bash ./setup-mac.sh ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

# ---------------------------------------------------------------- Xcode
step "Checking Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  fail "Xcode isn't ready. Install Xcode from the Mac App Store, open it once
  (let it install components), then run:
    sudo xcode-select -s /Applications/Xcode.app
  and run this script again."
fi
xcodebuild -version
# First-launch tasks (license, components). Harmless if already done.
xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
# The Apple Watch app needs Xcode's watchOS support (a one-time download of
# a few GB if it isn't installed yet).
if ! xcodebuild -showsdks 2>/dev/null | grep -qi watchos; then
  step "Downloading Xcode's watchOS support (one time, can take a while)"
  xcodebuild -downloadPlatform watchOS || fail "Couldn't download watchOS support. Open Xcode →
  Settings → Components (or Platforms) → watchOS → Get, then run this script again."
fi

# ---------------------------------------------------------------- XcodeGen
step "Checking XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is missing. Install it with the one line from https://brew.sh
  (follow the 'Next steps' it prints), then run this script again."
  fi
  brew install xcodegen
fi
xcodegen --version

# ---------------------------------------------------------------- Team ID
find_team_id() {
  # 1) From an existing "Apple Development" signing certificate (OU = Team ID).
  local subj
  subj=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null || true)
  if [ -n "$subj" ]; then
    echo "$subj" | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1
    return
  fi
  # 2) From the teams Xcode knows about (after signing in under Settings → Accounts).
  defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -nE 's/.*teamID = "?([A-Z0-9]{10})"?;.*/\1/p' | head -1
}

[ -z "$TEAM_ID" ] && TEAM_ID="$SAVED_TEAM"
if [ -z "$TEAM_ID" ]; then
  TEAM_ID=$(find_team_id || true)
  [ -n "$TEAM_ID" ] && echo "Found your Team ID: $TEAM_ID"
fi
[ -z "$BUNDLE_ID" ] && BUNDLE_ID="$SAVED_BUNDLE"
SAVED_TEAM="$TEAM_ID"; SAVED_BUNDLE="$BUNDLE_ID"; save_settings
DEFAULT_BUNDLE_ID=$(sed -nE 's/.*EC_APP_BUNDLE_ID: ([^ ]+)  # app bundle ID.*/\1/p' project.yml)
APP_BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
[ -n "$APP_BUNDLE_ID" ] || fail "Couldn't read the app's bundle ID (EC_APP_BUNDLE_ID) from project.yml."
[ -n "$BUNDLE_ID" ] && echo "Using your bundle ID $BUNDLE_ID"

# ---------------------------------------------------------------- Project
step "Generating EightCount.xcodeproj"
xcodegen generate

if [ "$REFRESH" = 1 ]; then
  : # the background refresh skips the extra compile check (the real build below checks anyway)
else
step "Compile check (no signing, 1–3 minutes the first time)"
if xcodebuild build -project EightCount.xcodeproj -scheme EightCount \
     -configuration Debug -destination 'generic/platform=iOS' \
     -derivedDataPath build/check CODE_SIGNING_ALLOWED=NO -quiet > build.log 2>&1; then
  echo "✓ Compiles."
else
  echo "Compile check FAILED. Errors:"
  grep -E "error:" build.log | sort -u || tail -40 build.log
  echo "Full log: $(pwd)/build.log"
  [ "$INSTALL" = 1 ] && fail "Fix the build errors first (or ask Claude Code with the log)."
fi
fi

# ---------------------------------------------------------------- iPhone
if [ "$INSTALL" = 1 ]; then
  [ -n "$TEAM_ID" ] || fail "No Apple Team found. In Xcode: Settings (⌘,) → Accounts → + →
  Apple Account → sign in. Then run this script again
  (or pass it: ./setup-mac.sh --install --team ABCDE12345)."

  step "Looking for your iPhone"
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  DEVICE_INFO=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
best = None
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") != "iOS" or hw.get("deviceType", "iPhone") != "iPhone":
        continue
    # Only real iPhones: devicectl can also list simulators ("virtual").
    if hw.get("reality", "physical") != "physical":
        continue
    conn = d.get("connectionProperties", {})
    props = d.get("deviceProperties", {})
    row = [d.get("identifier", ""), hw.get("udid", ""), props.get("name", "iPhone"),
           conn.get("pairingState", ""), props.get("developerModeStatus", ""),
           conn.get("tunnelState", "")]
    # Prefer a device that is paired and currently connected.
    if best is None or (row[3] == "paired" and row[5] != "unavailable"):
        best = row
print("|".join(best) if best else "")
PY
)
  rm -f "$JSON"
  [ -n "$DEVICE_INFO" ] || soft_stop "No iPhone found. Unlock it and make sure it's on the same Wi-Fi as
  this Mac (or connect the cable). The very first time it must be connected by
  cable and you tap \"Trust This Computer\". Then run this script again."
  IFS='|' read -r DEVICE_ID DEVICE_UDID DEVICE_NAME PAIRING DEVMODE _ <<< "$DEVICE_INFO"
  echo "Found: $DEVICE_NAME ($DEVICE_UDID) — pairing: ${PAIRING:-?}, developer mode: ${DEVMODE:-?}"
  [ "$PAIRING" = "paired" ] || fail "The iPhone isn't paired yet. Unlock it, tap \"Trust\", enter
  your passcode, then run this script again."
  if [ "$DEVMODE" = "disabled" ]; then
    fail "Developer Mode is off. On the iPhone: Settings → Privacy & Security → Developer Mode
  → on → Restart → after restart tap \"Turn On\". Then run this script again."
  fi

  # Free Apple ID signatures last 7 days. Throw away a cached signing profile
  # for this app that runs out within 4 days, so Xcode makes a fresh one.
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
             "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
      [ -e "$f" ] || continue
      info=$(security cms -D -i "$f" 2>/dev/null | python3 -c '
import sys, plistlib, calendar
d = plistlib.loads(sys.stdin.buffer.read())
print(d.get("Entitlements", {}).get("application-identifier", "-"),
      calendar.timegm(d["ExpirationDate"].timetuple()))' 2>/dev/null) || continue
      appid=${info% *}; exp=${info##* }
      case "$appid" in *".$APP_BUNDLE_ID") ;; *) continue ;; esac
      if [ $((exp - NOW)) -lt $((4 * 86400)) ]; then
        echo "Replacing an old signing profile (ran out $(date -r "$exp" '+%a %d %b'))."
        rm -f "$f"
      fi
    done
  done

  step "Building and signing for $DEVICE_NAME (team $TEAM_ID)"
  if ! xcodebuild build -project EightCount.xcodeproj -scheme EightCount \
       -configuration Debug -destination "platform=iOS,id=$DEVICE_UDID" \
       -derivedDataPath build/device \
       -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
       DEVELOPMENT_TEAM="$TEAM_ID" EC_APP_BUNDLE_ID="$APP_BUNDLE_ID" \
       > device-build.log 2>&1; then
    echo "Signing/build failed:"
    grep -E "error:" device-build.log | sort -u | head -20 || tail -40 device-build.log
    if grep -qiE "bundle identifier|App ID|is not available" device-build.log; then
      echo
      echo "→ The bundle ID is probably taken. Run again with your own, e.g.:"
      echo "  ./setup-mac.sh --install --bundle-id com.$(whoami | tr -cd 'a-z0-9').eightcount"
    fi
    if grep -qiE "No Accounts|account|sign in" device-build.log; then
      echo
      echo "→ Sign in to Xcode: Settings (⌘,) → Accounts → + → Apple Account."
    fi
    fail "Full log: $(pwd)/device-build.log"
  fi
  APP=build/device/Build/Products/Debug-iphoneos/EightCount.app
  echo "✓ Built and signed."

  # When does this build's signature run out?
  NEW_EXPIRES=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | python3 -c '
import sys, plistlib, calendar
print(calendar.timegm(plistlib.loads(sys.stdin.buffer.read())["ExpirationDate"].timetuple()))' 2>/dev/null || echo 0)
  [ "$NEW_EXPIRES" -gt 0 ] && echo "This build works until $(date -r "$NEW_EXPIRES")."

  step "Installing on $DEVICE_NAME"
  if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP"; then
    soft_stop "Couldn't install right now (is the iPhone locked or out of Wi-Fi range?)."
  fi
  printf 'LAST_OK=%s\nEXPIRES=%s\n' "$(date +%s)" "$NEW_EXPIRES" > "$STATE_FILE"
  if [ "$REFRESH" = 1 ]; then
    echo "✓ Refreshed in the background."
    if [ -n "$NEW_HEAD" ] && [ "$NEW_HEAD" != "$OLD_HEAD" ]; then
      notify "Updated to the newest version (works until $(date -r "$NEW_EXPIRES" '+%a %d %b'))."
    fi
    exit 0
  fi

  step "Launching EightCount"
  if xcrun devicectl device process launch --device "$DEVICE_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1; then
    echo "✓ EightCount is running on your iPhone."
  else
    echo "Installed, but iOS didn't let it start yet. With a free Apple ID do this once:"
    echo "  iPhone Settings → General → VPN & Device Management → your Apple ID → Trust"
    echo "Then tap the EightCount icon on your home screen."
  fi
  echo
  echo "Free Apple ID: the app stops opening after 7 days — run the update again"
  echo "(double-click \"Update EightCount\" on the Desktop, or ./setup-mac.sh --update)."
  echo "Wi-Fi is enough; your projects and notes stay."
fi

# ---------------------------------------------------------------- Xcode
if [ "$OPEN" = 1 ]; then
  step "Opening Xcode"
  open EightCount.xcodeproj
fi
echo
echo "Done."
