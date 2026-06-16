#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jizhi.crash-notify"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$DIR/crash-notify.sh"        # 直接从仓库跑,纯用户级,免 sudo
UID_NUM="$(id -u)"

chmod +x "$BIN"

# 1) 装 LaunchAgent(用户域,通知要在 GUI 会话里弹)
mkdir -p "$HOME/Library/LaunchAgents"
install -m 644 "$DIR/${LABEL}.plist" "$PLIST"

# 2) 打基线:把现有崩溃全部标记为已读,只通知此后的新崩溃
"$BIN" seed

# 3) 加载
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"

echo "installed (用户级, 无需 sudo)."
echo "日志:     ~/Library/Logs/crash-notify.log"
echo "自测横幅: /opt/homebrew/bin/terminal-notifier -title '💥 测试' -message ok"
