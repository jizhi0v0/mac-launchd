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
# RC 名 = wake-<工作目录名>-<随机>（spawn 里拼）。
# - claude 默认就开 RC（settings 的 remoteControlAtStartup），加 --remote-control 只为拿一个
#   「我们可控、可精准回收、App 里看得懂」的名字，不是为了开启 RC。
# - 目录名放前面：App 会话列表会截断，把目录名摆前面才能一眼看出这会话在哪个项目
#   （之前是 wake-<主机>-<时间戳>，截断后只剩主机，看不出目录）。
# - 随机后缀：每次唯一，避免复用同名撞上服务端没回收的残留登记（#57715）。
# - wake- 前缀：供 reap 精准匹配（你别的 claude / 桌面 App 会话都不用 --remote-control wake-）。
WAKE_RC_TAG="${WAKE_RC_TAG:-wake}"
WAKE_SESSION="${WAKE_SESSION:-wake}"
WAKE_NO_PROXY="${WAKE_NO_PROXY:-localhost,127.0.0.1,::1,.local}"
WAKE_CAPTURE_TIMEOUT="${WAKE_CAPTURE_TIMEOUT:-45}"

log() { printf '%s [claude-wake] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v tmux >/dev/null || die "需要 tmux: brew install tmux"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "PATH 里找不到 claude（应在 ~/.local/bin）"

reap() {
  local pat="claude --remote-control ${WAKE_RC_TAG}-"
  tmux kill-session -t "$WAKE_SESSION" 2>/dev/null && log "reaped tmux session '$WAKE_SESSION'" || true
  # 两段式回收：① 先 SIGTERM 给 claude 机会优雅注销【云端】RC 登记（否则留服务端僵尸、
  # 空占 RC 槽，攒多了新会话就 "Session creation failed" #57715）；等几秒。② 还赖着的
  # （claude 可能扛 SIGTERM/SIGHUP）再 SIGKILL 强杀，保证【本地】不漏进程。
  # 按 wake- 前缀匹配：含本次 + 跨次残留所有 wake RC；前缀只命中本工具起的，不误伤别的 claude。
  if pkill -TERM -f "$pat" 2>/dev/null; then
    log "TERM wake RC (等其优雅注销云端登记)"
    local i; for i in 1 2 3 4 5 6 7 8; do
      pgrep -f "$pat" >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
  pkill -KILL -f "$pat" 2>/dev/null && log "KILL 残留 wake RC" || true
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

  # 凭据：用本机 keychain 登录态（跟 Claude App 一样），不注入 CLAUDE_CODE_OAUTH_TOKEN。
  # 为什么不用 setup-token：它是 inference-only、缺 user:sessions:claude_code scope，
  # 开不了 RC（"Session creation failed"，#33105）——而 wake 的全部意义就是 RC。
  # 代价：keychain 登录靠 refreshToken，长期无人值守、refreshToken 一废需人肉重登一次；
  # 但 RC 没有长效 full-scope token 这个选项，只能这样。

  # RC 名 = wake-<工作目录名>-<随机>，见 WAKE_RC_TAG 注释。目录名清洗掉非常规字符、限长，
  # 让 App 列表一眼看出会话在哪个项目；随机后缀保证每次唯一。
  local dname; dname=$(basename "$dir" | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c1-28)
  [ -n "$dname" ] || dname="dir"
  local rc="${WAKE_RC_TAG}-${dname}-$(openssl rand -hex 3 2>/dev/null || printf '%s' "$$")"
  # claude --remote-control 要 PTY，塞进 tmux。dir 走 tmux -c（不进内层命令串，
  # 避免任何引号/注入问题）；PATH+代理透传进内层 shell。
  local cmd="export PATH='$PATH'; ${px}exec '$CLAUDE_BIN' --remote-control '$rc'"
  tmux new-session -d -s "$WAKE_SESSION" -x 220 -y 50 -c "$dir" "$cmd"
  log "spawned RC '$rc' @ $dir"
}

# 盯 pane 直到出现 claude.ai/code 接管链接；看到失败 banner 立即报错。
# 失败（注册失败 / 超时）时先 reap 掉这个起不来的会话，别让它（偶发卡死那种空白 claude）
# 一直挂着空占资源/RC 槽，要等下次 wake 才被收。
capture_url() {
  local i pane url
  for i in $(seq 1 "$WAKE_CAPTURE_TIMEOUT"); do
    pane=$(tmux capture-pane -t "$WAKE_SESSION" -p 2>/dev/null || true)
    printf '%s' "$pane" | grep -qiE 'remote.control failed|session creation failed' \
      && { reap; die "RC 注册失败（见 claude 调试日志 ~/.claude/logs）"; }
    url=$(printf '%s' "$pane" | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_]+' | head -1)
    [ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
    sleep 1
  done
  reap
  die "等了 ${WAKE_CAPTURE_TIMEOUT}s 没拿到 session URL（已 reap）"
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
