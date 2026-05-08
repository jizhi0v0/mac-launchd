#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.local.hy-mt-llama-server"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SRC="$DIR/${LABEL}.plist"

if ! command -v /opt/homebrew/bin/llama-server >/dev/null 2>&1; then
    echo "error: /opt/homebrew/bin/llama-server not found"
    echo "install via: brew install llama.cpp"
    exit 1
fi

# 真实用户（即使脚本被 sudo 触发）
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(/usr/bin/dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '{print $2}')

TMP_PLIST=$(mktemp)
sed -e "s|__USER__|$REAL_USER|g" -e "s|__HOME__|$REAL_HOME|g" "$SRC" > "$TMP_PLIST"

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo install -o root -g wheel -m 644 "$TMP_PLIST" "$PLIST"
rm -f "$TMP_PLIST"
sudo launchctl bootstrap system "$PLIST"

echo "installed as system LaunchDaemon (runs as $REAL_USER, starts at boot)"
echo "endpoint: http://127.0.0.1:8110"
echo "logs: /tmp/hy-mt-llama-server.{out,err}.log"
echo "first run will download model (~2GB) from HuggingFace, check err log for progress."
