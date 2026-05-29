#!/bin/bash
set -euo pipefail

LABEL="com.jizhi.anker-charge-monitor"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
BIN="/usr/local/bin/anker-charge-monitor.sh"

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo rm -f "$PLIST" "$BIN"

echo "uninstalled. 日志保留在 /var/log/anker-charge-monitor.log(如需清理请手动 rm)"
