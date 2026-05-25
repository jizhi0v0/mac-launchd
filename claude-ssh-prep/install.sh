#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jizhi.claude-ssh-prep"
SCRIPT="$DIR/claude-ssh-prep.sh"
PLIST_SRC="$DIR/${LABEL}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# 依赖检查（早失败比 daemon 跑起来才报错好）
command -v zstd >/dev/null || { echo "需要 zstd: brew install zstd"; exit 1; }

chmod +x "$SCRIPT"

# 把 plist 里的 __SCRIPT__ 占位符换成绝对路径，让 plist 跟仓库路径绑定
# （git pull 改脚本即生效，不用 reinstall plist）
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__SCRIPT__|$SCRIPT|g" "$PLIST_SRC" > "$PLIST_DST"

# 幂等：先 bootout（若已加载），再 bootstrap
launchctl bootout "gui/$UID" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"

# 立刻跑一次（RunAtLoad 也会触发，但显式 kickstart 让用户看到立即结果）
launchctl kickstart -k "gui/$UID/$LABEL"

echo "installed. logs: /tmp/claude-ssh-prep.{out,err}.log"
echo "status: launchctl print gui/$UID/$LABEL"
