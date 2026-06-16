#!/bin/bash
set -euo pipefail

LABEL="com.jizhi.crash-notify"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
rm -f "$PLIST"

echo "uninstalled (脚本在仓库里,无需删)."
echo "日志/状态保留:"
echo "  ~/Library/Logs/crash-notify.log"
echo "  ~/Library/Application Support/crash-notify/state.json"
echo "如需清理: rm -rf ~/Library/Application\\ Support/crash-notify ~/Library/Logs/crash-notify.*"
