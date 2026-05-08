#!/bin/bash
set -euo pipefail

LABEL="com.local.hy-mt-llama-server"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
USER_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# 卸载新版（system daemon）
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo rm -f "$PLIST"

# 兼容旧版（user agent）一并清理
launchctl bootout "gui/$UID" "$USER_PLIST" 2>/dev/null || true
rm -f "$USER_PLIST"

echo "uninstalled. (model cache in ~/Library/Caches/llama.cpp not removed)"
