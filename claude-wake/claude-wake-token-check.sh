#!/bin/bash
# claude-wake-token-check —— 盯着 wake 用的长效 Anthropic 凭据快到 1 年没,该重签前弹横幅。
#
# 为什么需要：CLAUDE_CODE_OAUTH_TOKEN（claude setup-token 签的）约 1 年到期，且是不透明
# 串、token 里读不出过期时间 —— 所以按「文件 mtime 年龄」近似（写入时刻=签发时刻）。一旦
# 它悄悄过期，wake 逃生舱会在你不知道、又正好不在的时候废掉。提前 ~1 个月唠叨你重签。
#
# 由 LaunchAgent 每天跑一次（StartCalendarInterval）。没配长效 token（文件不存在）= 你
# 选了继承本机登录态那条路，不是错误，静默退出、不打扰。
#
# 用法: claude-wake-token-check.sh        正常检查+按需通知（由 launchd 调）
#       claude-wake-token-check.sh now    无视冷却，强制现在评估并通知（手动验证用）
set -uo pipefail

OAUTH_FILE="${WAKE_OAUTH_FILE:-$HOME/.config/claude-wake/oauth-token}"
WARN_DAYS="${WAKE_TOKEN_WARN_DAYS:-330}"   # 超过这个天数就开始提醒（setup-token ~365 天到期）
COOLDOWN_DAYS="${WAKE_TOKEN_COOLDOWN_DAYS:-3}"  # 两次横幅最短间隔，避免每天刷屏
NOTIFIER="/opt/homebrew/bin/terminal-notifier"
STATE="$HOME/Library/Application Support/claude-wake/tokencheck.last"
LOG="$HOME/Library/Logs/claude-wake-token-check.log"
FORCE="${1:-}"

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# 文件不在 = 走继承登录态那条路，不该提醒
[ -s "$OAUTH_FILE" ] || { log "no oauth-token file ($OAUTH_FILE) — 继承登录态模式，跳过"; exit 0; }

now=$(date +%s)
mtime=$(stat -f %m "$OAUTH_FILE")
age_days=$(( (now - mtime) / 86400 ))

if [ "$age_days" -lt "$WARN_DAYS" ] && [ "$FORCE" != "now" ]; then
  log "token 年龄 ${age_days}d < ${WARN_DAYS}d，无需提醒"
  exit 0
fi

# 冷却：上次提醒不足 COOLDOWN_DAYS 天就别再弹（强制模式无视）
if [ "$FORCE" != "now" ] && [ -f "$STATE" ]; then
  last=$(stat -f %m "$STATE")
  if [ $(( (now - last) / 86400 )) -lt "$COOLDOWN_DAYS" ]; then
    log "token 年龄 ${age_days}d，但在 ${COOLDOWN_DAYS}d 冷却内，跳过横幅"
    exit 0
  fi
fi

left=$(( 365 - age_days ))
if [ "$age_days" -ge 365 ]; then
  title="🔑 claude-wake token 可能已过期"
  sub="已签发 ${age_days} 天（≥1 年）"
  sound="Sosumi"
else
  title="🔑 claude-wake token 快到期"
  sub="已签发 ${age_days} 天，约剩 ${left} 天"
  sound="Basso"
fi
msg="重签: claude setup-token → 覆写 $OAUTH_FILE"

if [ -x "$NOTIFIER" ]; then
  "$NOTIFIER" -title "$title" -subtitle "$sub" -message "$msg" \
    -group "claude-wake-token" -sound "$sound" \
    >/dev/null 2>&1 || log "WARN terminal-notifier 失败"
else
  osascript -e "display notification \"$msg\" with title \"$title\" subtitle \"$sub\"" \
    >/dev/null 2>&1 || log "WARN osascript 通知失败"
fi

touch "$STATE"
log "NOTIFY: $title — $sub"
