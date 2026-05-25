#!/bin/bash
set -euo pipefail

LABEL="com.jizhi.claude-ssh-prep"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$UID" "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"

echo "uninstalled. 数据保留：~/.claude/remote/{srv,ccd-cli}"
