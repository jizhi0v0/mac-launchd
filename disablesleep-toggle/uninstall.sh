#!/bin/bash
set -euo pipefail

LABEL="com.jizhi.disablesleep-toggle"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
BIN="/usr/local/bin/disablesleep-toggle.sh"

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo rm -f "$PLIST" "$BIN"
sudo pmset -a disablesleep 0

echo "uninstalled."
