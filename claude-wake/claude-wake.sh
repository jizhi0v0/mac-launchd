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
# 多会话：每次唤醒一个独立 tmux 会话 cw-<id>，可并存任意多个，全部按 <id> 寻址、互不影响。
# 用法：claude-wake.sh wake [dir]      # 阻塞式：起独立会话 + 等到 URL 打到 stdout（Shortcut/CLI）
#       claude-wake.sh spawn-bg [dir]  # 起独立会话立刻返回，回 id=/rc=/dir=（SPA 流式起会话用）
#       claude-wake.sh peek  <id>      # 打印该会话 pane 内容（server 轮询判进度用）
#       claude-wake.sh alive <id>      # 该会话还在不在（yes/no）
#       claude-wake.sh list            # 所有 live 会话：每行 id<TAB>rc<TAB>dir
#       claude-wake.sh dump            # 所有 live 会话的元信息 + pane（server 一次拿全量，省 subprocess）
#       claude-wake.sh status          # 所有 live 会话的 URL：每行 rc<TAB>dir<TAB>url
#       claude-wake.sh reap [id] [rc]  # 精准收一个会话；无 id = 全部收（= reap-all）
#       claude-wake.sh reap-all        # 全部收掉（卸载用）
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
# 多会话：每次唤醒一个【独立】tmux 会话 cw-<id>（id 随机），互不影响，可并存任意多个。
# 旧的"固定一个 wake 会话、新唤醒先 reap 掉旧的"模型已废弃——那样第二次唤醒会杀掉你正在
# 接管使用的第一个会话。现在每个会话独立寻址，reap 只精准收指定 id，不波及其它。
WAKE_SESS_PREFIX="${WAKE_SESS_PREFIX:-cw-}"
sess() { printf '%s%s' "$WAKE_SESS_PREFIX" "$1"; }   # id → tmux 会话名
WAKE_NO_PROXY="${WAKE_NO_PROXY:-localhost,127.0.0.1,::1,.local}"
# 等 URL 的上限。放宽到 45s：别误杀"其实已注册 RC、只是 URL 慢一两拍"的好会话——
# 误杀会在云端留一个 archived 尸体。真卡死由下面的"空白早判"快速识别，不靠这个超时。
WAKE_CAPTURE_TIMEOUT="${WAKE_CAPTURE_TIMEOUT:-45}"

# 根因修复：LaunchAgent 亲自起的 tmux server 处在 launchd bootstrap 上下文，里面 claude 卡死、
# 连它的 tmux 客户端命令也卡。所以 wake 绝不自己起 server —— 只挂到一个【在 GUI 会话里起好的】
# 常驻 host server（专用 socket，由登录项/host 脚本保活，见 claude-wake-tmux-host）。
# 固定 TMUX_TMPDIR 让 host 与 wake 命中同一个 socket。
WAKE_TMUX_SOCK="${WAKE_TMUX_SOCK:-claude-wake}"
export TMUX_TMPDIR="${WAKE_TMUX_TMPDIR:-/tmp}"
T="$(command -v tmux) -L $WAKE_TMUX_SOCK"   # 所有 tmux 操作都走这个专用 server

log() { printf '%s [claude-wake] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v tmux >/dev/null || die "需要 tmux: brew install tmux"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "PATH 里找不到 claude（应在 ~/.local/bin）"

# 两段式回收一个 RC 进程：先 SIGTERM 给 claude 机会优雅注销【云端】RC 登记（否则留服务端
# 僵尸、空占 RC 槽，攒多了新会话就 "Session creation failed" #57715）、等几秒；还赖着的
# （claude 可能扛 SIGTERM/SIGHUP）再 SIGKILL 兜底，保证【本地】不漏进程。pat 必须能精准
# 命中目标，别误伤别的 claude / 其它并存的 wake 会话。
kill_rc_proc() {
  local pat="$1"
  if pkill -TERM -f "$pat" 2>/dev/null; then
    log "TERM RC（等其注销云端登记）: $pat"
    local i; for i in 1 2 3 4 5 6 7 8; do
      pgrep -f "$pat" >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
  pkill -KILL -f "$pat" 2>/dev/null && log "KILL 残留 RC: $pat" || true
}

# 精准收【一个】会话：读它的 RC 名（spawn 时存进 tmux @rc 选项），kill 掉 tmux 会话，再两段式
# 杀掉【正好这一个】RC 进程——不波及其它并存的 wake 会话。rc 也可由调用方直接给（server 有记账）。
reap_one() {
  local id="$1" rc="${2:-}" s
  s="$(sess "$id")"
  [ -n "$rc" ] || rc="$($T show-options -t "$s" -v @rc 2>/dev/null || true)"
  $T kill-session -t "$s" 2>/dev/null && log "reaped tmux session '$s'" || true
  if [ -n "$rc" ]; then
    kill_rc_proc "claude --remote-control $rc"
  else
    log "reap $id：没拿到 RC 名（会话可能已没），跳过进程清理"
  fi
}

# 全部收掉（卸载 / 「全部收掉」兜底用）：杀所有 cw-* 会话 + 所有 wake- RC。
reap_all() {
  $T list-sessions -F '#{session_name}' 2>/dev/null | grep "^$WAKE_SESS_PREFIX" \
    | while read -r s; do $T kill-session -t "$s" 2>/dev/null && log "reaped '$s'" || true; done
  kill_rc_proc "claude --remote-control ${WAKE_RC_TAG}-"
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
  # SESSION_ID / RC_NAME 是全局（非 local）——spawn-bg 起完即退，要把 id/rc 回给调用方
  # （server）记账、展示、精准回收。id = 随机 hex；tmux 会话 cw-<id>；RC 名 wake-<目录名>-<id>
  # （目录名给 App 列表一眼看出项目，id 给机器精准匹配）。
  SESSION_ID="$(openssl rand -hex 3 2>/dev/null || printf '%s' "$$")"
  RC_NAME="${WAKE_RC_TAG}-${dname}-${SESSION_ID}"
  # claude --remote-control 要 PTY，塞进 tmux。dir 走 tmux -c（不进内层命令串，
  # 避免任何引号/注入问题）；PATH+代理透传进内层 shell。
  local cmd="export PATH='$PATH'; ${px}exec '$CLAUDE_BIN' --remote-control '$RC_NAME'"
  # 只挂到常驻 host server。若它没在跑（应由登录项/host 保活），这里会现起一个【坏上下文】的，
  # 大概率卡——所以先检查，缺了就明确报错，别默默起个坏的。
  $T has-session -t _host 2>/dev/null || $T list-sessions >/dev/null 2>&1 \
    || die "tmux host server 没在跑（应由 claude-wake-tmux-host 保活）。先跑 host 脚本/登录项。"
  local s; s="$(sess "$SESSION_ID")"
  $T new-session -d -s "$s" -x 220 -y 50 -c "$dir" "$cmd"
  # 把 RC 名和目录记到会话选项上，供 list / reap_one / status 之后读取（server 重启也不丢）。
  $T set-option -t "$s" @rc "$RC_NAME" >/dev/null 2>&1 || true
  $T set-option -t "$s" @dir "$dir" >/dev/null 2>&1 || true
  log "spawned '$s' RC '$RC_NAME' @ $dir"
}

# claude 偶发启动卡死（pane 全程空白、RC 注册不了，~1/十几次、按需复现不出）。卡住的瞬间
# 把进程调用栈 + 打开的连接/管道 dump 到日志，供事后定根因——这是唯一能抓到这种稀有竞态的办法。
dump_hang() {
  local id="$1" pid logf s
  s="$(sess "$id")"
  pid=$($T list-panes -t "$s" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pid" ] || return 0
  logf="/tmp/claude-wake-hang-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "# claude-wake hang @ $(date)  sess=$s  pid=$pid"
    echo "## 子进程"; ps -axo pid,ppid,stat,command | awk -v p="$pid" '$2==p'
    echo "## sample 调用栈"; sample "$pid" 2 2>/dev/null
    echo "## lsof（连接/管道）"; lsof -nP -p "$pid" 2>/dev/null
  } >"$logf" 2>&1
  log "卡死诊断已 dump → $logf（下次定根因看它）"
}

# 盯 pane 直到出现接管链接。失败/卡死返回非 0（不 die，交给上层重试）。
# 按【墙钟时间】判定（不是循环次数）——守护进程里 tmux 命令偶尔慢，按次数会判太晚。
# 健康 claude 几秒就渲染 TUI；pane 空白持续 ${WAKE_HANG_BLANK}s = 冷启动卡死，早判→dump→reap→上层重试。
WAKE_HANG_BLANK="${WAKE_HANG_BLANK:-12}"
# 阻塞式（Shortcut/CLI 的 wake）用：盯一个会话的 pane 直到出 URL；失败/卡死只收掉【这一个】
# （reap_one $id），不动其它并存会话。流式 SPA 不走这里（它由 server 端无超时轮询 list）。
capture_url() {
  local id="$1" s start=$SECONDS blank_since=$SECONDS pane url lines now
  s="$(sess "$id")"
  while [ $((SECONDS - start)) -lt "$WAKE_CAPTURE_TIMEOUT" ]; do
    pane=$($T capture-pane -t "$s" -p 2>/dev/null || true)
    printf '%s' "$pane" | grep -qiE 'remote.control failed|session creation failed' \
      && { log "RC 注册失败 banner"; dump_hang "$id"; reap_one "$id"; return 1; }
    url=$(printf '%s' "$pane" | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_]+' | head -1)
    [ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
    lines=$(printf '%s' "$pane" | grep -c .)
    now=$SECONDS
    [ "$lines" -ge 2 ] && blank_since=$now   # 一渲染出内容就清零计时
    if [ $((now - blank_since)) -ge "$WAKE_HANG_BLANK" ]; then
      log "pane 空白持续 $((now - blank_since))s → 判定冷启动卡死"; dump_hang "$id"; reap_one "$id"; return 1
    fi
    sleep 1
  done
  log "等了 ${WAKE_CAPTURE_TIMEOUT}s 没拿到 URL"; dump_hang "$id"; reap_one "$id"; return 1
}

case "${1:-wake}" in
  wake)
    # 阻塞式（Shortcut/CLI）：起一个【独立】会话 + 等到 URL 打到 stdout；失败只收掉自己这一个，
    # 不动别人。多会话模型：不再 reap 其它会话，重复调用会并存累积（由 list/UI 管理）。
    WDIR="${2:-$WAKE_DIR_DEFAULT}"
    spawn "$WDIR"
    url="$(capture_url "$SESSION_ID")" \
      || die "没起来（已收掉本次，诊断见 /tmp/claude-wake-hang-*.log）。请重试一次。"
    printf '%s\n' "$url"
    ;;
  # ---- 流式唤醒原子动作（server 编排无超时轮询）。多会话：全部按 <id> 寻址，互不影响 ----
  #   spawn-bg [dir]   起一个独立会话立刻返回，回 id=/rc=/dir= 供 server 记账（不 reap 任何别人）。
  #   peek  <id>       打印该会话 pane（server 据此判 booting/rendering/ready + 回终端尾巴）。
  #   alive <id>       该会话还在不在（yes/no）。
  #   list             列出所有 live 会话：每行 id<TAB>rc<TAB>dir（从 tmux 读，server 重启不丢）。
  #   reap  <id> [rc]  精准收一个；reap（无 id）= reap-all 兜底。
  #   reap-all         全部收掉（卸载用）。
  spawn-bg)
    WDIR="${2:-$WAKE_DIR_DEFAULT}"
    spawn "$WDIR"
    printf 'id=%s\n' "$SESSION_ID"
    printf 'rc=%s\n' "$RC_NAME"
    printf 'dir=%s\n' "$WDIR"
    ;;
  peek)   $T capture-pane -t "$(sess "${2:?用法: peek <id>}")" -p 2>/dev/null || true ;;
  alive)  $T has-session -t "$(sess "${2:?用法: alive <id>}")" 2>/dev/null && echo yes || echo no ;;
  list)
    $T list-sessions -F '#{session_name}' 2>/dev/null | grep "^$WAKE_SESS_PREFIX" \
      | while read -r s; do
          id="${s#"$WAKE_SESS_PREFIX"}"
          rc="$($T show-options -t "$s" -v @rc 2>/dev/null || true)"
          dir="$($T show-options -t "$s" -v @dir 2>/dev/null || true)"
          printf '%s\t%s\t%s\n' "$id" "$rc" "$dir"
        done
    ;;
  dump)
    # 一次性吐出所有 live 会话的元信息 + pane 内容，让 server 一个 subprocess 拿全量（避免它
    # 对每个会话各 spawn 一次 wake.sh：会话一多、轮询一叠加，tmux 命令排队、延迟雪崩）。
    # 格式：每个会话先一行哨兵 "@@CW<TAB>id<TAB>rc<TAB>dir"，紧跟其 pane 原样多行，直到下一个哨兵。
    $T list-sessions -F '#{session_name}' 2>/dev/null | grep "^$WAKE_SESS_PREFIX" \
      | while read -r s; do
          id="${s#"$WAKE_SESS_PREFIX"}"
          rc="$($T show-options -t "$s" -v @rc 2>/dev/null || true)"
          dir="$($T show-options -t "$s" -v @dir 2>/dev/null || true)"
          printf '@@CW\t%s\t%s\t%s\n' "$id" "$rc" "$dir"
          $T capture-pane -t "$s" -p 2>/dev/null || true
        done
    ;;
  reap)
    if [ -n "${2:-}" ]; then reap_one "$2" "${3:-}"; else reap_all; fi
    ;;
  reap-all) reap_all ;;
  status)
    # 列出所有 live 会话的 URL（多会话）：每行 rc<TAB>dir<TAB>url。
    n=0
    while IFS=$'\t' read -r id rc dir; do
      [ -n "$id" ] || continue
      n=$((n + 1))
      u="$($T capture-pane -t "$(sess "$id")" -p 2>/dev/null \
            | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_]+' | head -1)"
      printf '%s\t%s\t%s\n' "$rc" "$dir" "${u:-(无URL)}"
    done < <("$0" list)
    [ "$n" -gt 0 ] || echo "no wake session"
    ;;
  *) die "用法: claude-wake.sh wake|spawn-bg|peek <id>|alive <id>|list|reap [id]|reap-all|status [dir]" ;;
esac
