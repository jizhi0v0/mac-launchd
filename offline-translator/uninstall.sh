#!/bin/bash
set -euo pipefail

LABEL="com.local.offline-translator"
OLD_LABEL="com.local.hy-mt-llama-server"
AGENT="$HOME/Library/LaunchAgents/${LABEL}.plist"

# 卸载当前版本（MLX user LaunchAgent）
launchctl bootout "gui/$UID" "$AGENT" 2>/dev/null || true
rm -f "$AGENT"

# 兼容清理旧版 llama.cpp（system daemon + 可能的旧 user agent）
sudo launchctl bootout system "/Library/LaunchDaemons/${OLD_LABEL}.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/${OLD_LABEL}.plist"
launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/${OLD_LABEL}.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/${OLD_LABEL}.plist"

echo "uninstalled."
echo "venv + 模型仍在 ~/.local/share/offline-translator（如需彻底清理可手动 rm -rf）。"
