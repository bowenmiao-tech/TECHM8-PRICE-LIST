#!/bin/bash
# Installs two LaunchAgents for this Mac user:
#   com.techm8.crazyparts.monthly – 05:00 on days 1–11, runs that day's brand
#   com.techm8.crazyparts.queue   – every minute, runs Admin "Run Now" requests
# Pass a start time to change 05:00: install-crazyparts-launchd.sh 04:30
# Pass --uninstall to remove both.
set -euo pipefail
source "$(dirname "$0")/crazyparts-common.sh"

agents="$HOME/Library/LaunchAgents"
monthly="com.techm8.crazyparts.monthly"
queue="com.techm8.crazyparts.queue"
domain="gui/$(id -u)"

for label in "$monthly" "$queue"; do
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f "$agents/$label.plist"
done
if [[ "${1:-}" == "--uninstall" ]]; then
  echo 'Crazy Parts LaunchAgents removed.'
  exit 0
fi

start="${1:-05:00}"
[[ "$start" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { echo 'Start time must be HH:MM' >&2; exit 1; }
hour=$((10#${BASH_REMATCH[1]}))
minute=$((10#${BASH_REMATCH[2]}))

calendar=''
for day in $(seq 1 11); do
  calendar+="    <dict><key>Day</key><integer>$day</integer><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>$minute</integer></dict>
"
done

mkdir -p "$agents"
cat > "$agents/$monthly.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$monthly</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$MAC_SCRIPT_DIR/run-crazyparts-scheduled.sh</string></array>
  <key>WorkingDirectory</key><string>$PROJECT_ROOT</string>
  <key>StartCalendarInterval</key>
  <array>
$calendar  </array>
  <key>StandardOutPath</key><string>$LOG_DIR/monthly.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/monthly.log</string>
  <key>ProcessType</key><string>Standard</string>
</dict>
</plist>
PLIST

cat > "$agents/$queue.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$queue</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$MAC_SCRIPT_DIR/process-crazyparts-run-queue.sh</string></array>
  <key>WorkingDirectory</key><string>$PROJECT_ROOT</string>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/queue.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/queue.log</string>
  <key>ProcessType</key><string>Standard</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$domain" "$agents/$monthly.plist"
launchctl bootstrap "$domain" "$agents/$queue.plist"
echo "Installed: brand updates at $start on days 1–11, Admin Run Now queue checked every minute."
echo "Logs: $LOG_DIR"
