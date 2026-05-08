#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jizhi.disablesleep-toggle"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
BIN="/usr/local/bin/disablesleep-toggle.sh"

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo install -o root -g wheel -m 755 "$DIR/disablesleep-toggle.sh" "$BIN"
sudo install -o root -g wheel -m 644 "$DIR/${LABEL}.plist"        "$PLIST"
sudo launchctl bootstrap system "$PLIST"

echo "installed. log: /var/log/disablesleep-toggle.log"
