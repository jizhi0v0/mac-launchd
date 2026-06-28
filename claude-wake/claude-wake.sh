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

# 插件钩子（codex 的 SessionStart/SessionEnd/Stop）命令里写死 `node`，但 launchd 窄 PATH
# 里没有 node（nvm 装的不在），于是 wake 会话报 "node: command not found"。bun 跟这些钩子
# 兼容（已验证），且在 /opt/homebrew/bin（已在上面 PATH 里）、比 nvm 版本目录稳。给它造个
# 叫 node 的垫片放进 wake 私有 bin 并入 PATH——满足字面量 `node` 调用。bun 不在就跳过（红字
# 无害，非阻塞）。
if BUN_BIN="$(command -v bun)"; then
  WAKE_NODE_SHIM="$HOME/.config/claude-wake/bin"
  mkdir -p "$WAKE_NODE_SHIM"
  ln -sf "$BUN_BIN" "$WAKE_NODE_SHIM/node"
  export PATH="$WAKE_NODE_SHIM:$PATH"
fi

# 默认工作目录：用 /tmp 下的空目录，claude 在这秒起；指到 $HOME 那种巨目录会冷启动到
# 超时。带 mkdir -p 兜底——/tmp 被系统周期清理后下次 wake 自动重建。要在某仓库里起会话，
# 走 ?dir=（server 的 /dirs 选文件夹）单次覆盖即可。
WAKE_DIR_DEFAULT="${WAKE_DIR:-/tmp/claude-wake-cwd}"
mkdir -p "$WAKE_DIR_DEFAULT" 2>/dev/null || true
# RC 名 = wake-<主机> 前缀 + 每次唯一后缀（spawn 里拼）。
# - claude 默认就开 RC（settings 的 remoteControlAtStartup），加 --remote-control 只为拿一个
#   「我们可控、可精准回收」的名字，不是为了开启 RC。
# - 唯一后缀：避免复用同名撞上服务端没回收的残留注册（#57715 那类 "Session creation failed"）。
# - wake-<主机> 前缀：让 reap 能按前缀只杀 wake 起的 RC，不误伤你手头别的 claude。
WAKE_RC_PREFIX="${WAKE_RC_PREFIX:-wake-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
WAKE_SESSION="${WAKE_SESSION:-wake}"
WAKE_NO_PROXY="${WAKE_NO_PROXY:-localhost,127.0.0.1,::1,.local}"
WAKE_CAPTURE_TIMEOUT="${WAKE_CAPTURE_TIMEOUT:-45}"
# 给无人值守 wake 会话用的长效 Anthropic 凭据（claude setup-token 签的，写进这个文件）。
# 不设/文件不存在 → 退回继承本机交互登录态（几小时刷一次，refreshToken 一废就得人肉重登）。
WAKE_OAUTH_FILE="${WAKE_OAUTH_FILE:-$HOME/.config/claude-wake/oauth-token}"

log() { printf '%s [claude-wake] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v tmux >/dev/null || die "需要 tmux: brew install tmux"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "PATH 里找不到 claude（应在 ~/.local/bin）"

reap() {
  tmux kill-session -t "$WAKE_SESSION" 2>/dev/null && log "reaped tmux session '$WAKE_SESSION'" || true
  # 真 bug 修复：旧版发 SIGTERM，claude 跟扛 SIGHUP 一样扛住 → 漏成常驻僵尸、空占 RC 槽
  # （槽位只进不出，攒多了新会话就 "Session creation failed"）。改 -KILL 杀不掉才怪。
  # 按 RC 名前缀匹配：含本次会话 + 跨次残留的所有 wake RC（新旧后缀都覆盖），且前缀只命中
  # 本工具起的，绝不误伤你手头别的 claude / 桌面 App 会话。
  pkill -KILL -f "claude --remote-control ${WAKE_RC_PREFIX}" 2>/dev/null && log "killed stray wake RC" || true
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

  # 长效凭据：有就注入 CLAUDE_CODE_OAUTH_TOKEN，claude 用它而非 keychain，和本机交互
  # 登录态彻底解耦（人肉重登/换号都不影响 wake）。没有就静默退回继承登录态。
  local tok=""
  if [ -r "$WAKE_OAUTH_FILE" ] && [ -s "$WAKE_OAUTH_FILE" ]; then
    tok="export CLAUDE_CODE_OAUTH_TOKEN='$(cat "$WAKE_OAUTH_FILE")'; "
    log "using long-lived oauth token from $WAKE_OAUTH_FILE"
  else
    log "no oauth-token file → 退回继承本机登录态（refreshToken 一废即失效）"
  fi

  # 每次唯一的 RC 名：前缀 + 时间戳 + 随机（openssl 没有就退回 PID），见 WAKE_RC_PREFIX 注释。
  local rc="${WAKE_RC_PREFIX}-$(date +%s)$(openssl rand -hex 2 2>/dev/null || printf '%s' "$$")"
  # claude --remote-control 要 PTY，塞进 tmux。dir 走 tmux -c（不进内层命令串，
  # 避免任何引号/注入问题）；PATH+代理+凭据透传进内层 shell。
  local cmd="export PATH='$PATH'; ${tok}${px}exec '$CLAUDE_BIN' --remote-control '$rc'"
  tmux new-session -d -s "$WAKE_SESSION" -x 220 -y 50 -c "$dir" "$cmd"
  log "spawned RC '$rc' @ $dir"
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
