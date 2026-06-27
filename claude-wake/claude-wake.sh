#!/bin/bash
# claude-wake 的实干层：按需 reap 掉旧的、spawn 一个全新的 claude --remote-control
# 会话，并把它的 claude.ai/code 接管链接打到 stdout。HTTP 前端（server.py）只管鉴权
# 和把请求转给我。
#
# 为什么是"唤醒"而不是"常驻"：RC 是一条活的云连接，网络抖动会把它打断进 archived
# 态，常驻会话于是变僵尸、抓不回来。改成每次现起一个全新会话 → 全新连接，没有陈旧
# 断链问题。而这个触发器本身不持有云连接（只是本地被 tailscale/surge 转进来的一次
# 性调用），所以抖动锁不住它。
#
# 用法：claude-wake.sh wake [dir]   # 起新会话，stdout 输出接管 URL
#       claude-wake.sh status       # 当前 wake 会话的 URL（若在）
#       claude-wake.sh reap         # 收掉当前 wake 会话
#
# stdout 只放 URL（成功时）；所有日志走 stderr，别污染给 HTTP 前端的返回。

set -uo pipefail

# LaunchAgent / tailscale 转进来的子进程 PATH 很窄：tmux 在 Homebrew、claude 在
# ~/.local/bin，都得显式补。
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

WAKE_DIR_DEFAULT="${WAKE_DIR:-$HOME}"
WAKE_RC_NAME="${WAKE_RC_NAME:-wake-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
WAKE_SESSION="${WAKE_SESSION:-wake}"
WAKE_NO_PROXY="${WAKE_NO_PROXY:-localhost,127.0.0.1,::1,.local}"
WAKE_CAPTURE_TIMEOUT="${WAKE_CAPTURE_TIMEOUT:-25}"

log() { printf '%s [claude-wake] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v tmux >/dev/null || die "需要 tmux: brew install tmux"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "PATH 里找不到 claude（应在 ~/.local/bin）"

reap() {
  tmux kill-session -t "$WAKE_SESSION" 2>/dev/null && log "reaped tmux session '$WAKE_SESSION'" || true
  # kill-session 的 SIGHUP claude 可能扛得住 → 按 RC 名兜底收残留
  pkill -f "claude --remote-control $WAKE_RC_NAME" 2>/dev/null && log "killed stray claude" || true
}

spawn() {
  local dir="${1:-$WAKE_DIR_DEFAULT}"
  [ -d "$dir" ] || die "dir 不存在: $dir"

  # 代理：LaunchAgent/tailscale 子进程不继承用户 shell 的 proxy env，但 RC 注册要
  # 连 Anthropic 云。本机走 Surge（127.0.0.1:6152），不带代理 → "Session creation
  # failed"。从 scutil 读系统级 HTTPS 代理补上（每次都重读，跟随换网）。
  local ph pp px=""
  ph=$(scutil --proxy 2>/dev/null | awk '/HTTPSProxy *: / {print $3; exit}')
  pp=$(scutil --proxy 2>/dev/null | awk '/HTTPSPort *: / {print $3; exit}')
  if [ -n "$ph" ] && [ -n "$pp" ]; then
    local u="http://$ph:$pp"
    px="export HTTPS_PROXY='$u' HTTP_PROXY='$u' https_proxy='$u' http_proxy='$u' NO_PROXY='$WAKE_NO_PROXY' no_proxy='$WAKE_NO_PROXY'; "
    log "using system HTTPS proxy $u"
  else
    log "no system HTTPS proxy (direct)"
  fi

  # claude --remote-control 要 PTY，塞进 tmux。dir 走 tmux -c（不进内层命令串，
  # 避免任何引号/注入问题）；PATH+代理透传进内层 shell。
  local cmd="export PATH='$PATH'; ${px}exec '$CLAUDE_BIN' --remote-control '$WAKE_RC_NAME'"
  tmux new-session -d -s "$WAKE_SESSION" -x 220 -y 50 -c "$dir" "$cmd"
  log "spawned RC '$WAKE_RC_NAME' @ $dir"
}

# 盯 pane 直到出现 claude.ai/code 接管链接；看到失败 banner 立即报错。
capture_url() {
  local i pane url
  for i in $(seq 1 "$WAKE_CAPTURE_TIMEOUT"); do
    pane=$(tmux capture-pane -t "$WAKE_SESSION" -p 2>/dev/null || true)
    printf '%s' "$pane" | grep -qiE 'remote.control failed|session creation failed' \
      && die "RC 注册失败（见 claude 调试日志 ~/.claude/logs）"
    url=$(printf '%s' "$pane" | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_]+' | head -1)
    [ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
    sleep 1
  done
  die "等了 ${WAKE_CAPTURE_TIMEOUT}s 没拿到 session URL"
}

case "${1:-wake}" in
  wake)   reap; spawn "${2:-$WAKE_DIR_DEFAULT}"; capture_url ;;
  reap)   reap ;;
  status)
    if tmux has-session -t "$WAKE_SESSION" 2>/dev/null; then
      tmux capture-pane -t "$WAKE_SESSION" -p 2>/dev/null \
        | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_]+' | head -1 \
        || echo "wake session 在，但没抓到 URL"
    else
      echo "no wake session"
    fi
    ;;
  *) die "用法: claude-wake.sh wake|reap|status [dir]" ;;
esac
