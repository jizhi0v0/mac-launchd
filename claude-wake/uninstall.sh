#!/bin/bash
set -euo pipefail

LABEL="com.jizhi.claude-wake"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
TC_LABEL="com.jizhi.claude-wake-tokencheck"
TC_DST="$HOME/Library/LaunchAgents/${TC_LABEL}.plist"
UID_NUM="$(id -u)"
PORT="${WAKE_PORT:-8765}"

launchctl bootout "gui/$UID_NUM" "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"

launchctl bootout "gui/$UID_NUM" "$TC_DST" 2>/dev/null || true
rm -f "$TC_DST"

# 收掉 tailscale serve 映射。优先精确关掉本端口；不行再整体 reset
# （装它时 serve 配置本是空的，reset 只清掉我们这一条）。
if command -v tailscale >/dev/null; then
  tailscale serve --https=443 off 2>/dev/null \
    || tailscale serve reset 2>/dev/null \
    || true
  echo "已撤销 tailscale serve（如还有别的 serve 映射，确认下 tailscale serve status）"
fi

# 收掉可能还开着的 wake 会话
PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH" \
  bash "$(dirname "$0")/claude-wake.sh" reap 2>/dev/null || true

echo "uninstalled. token 保留在 ~/.config/claude-wake/token（要清就手动 rm）。"
