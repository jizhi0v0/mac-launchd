#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jizhi.anker-charge-monitor"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
BIN="/usr/local/bin/anker-charge-monitor.sh"

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo install -o root -g wheel -m 755 "$DIR/anker-charge-monitor.sh" "$BIN"
sudo install -o root -g wheel -m 644 "$DIR/${LABEL}.plist"          "$PLIST"
sudo launchctl bootstrap system "$PLIST"

echo "installed. log: /var/log/anker-charge-monitor.log"
echo "实时跟踪:  tail -f /var/log/anker-charge-monitor.log"
echo "只看断开:  grep -E 'DISCONNECT|RECONNECT|PSLOG' /var/log/anker-charge-monitor.log"
