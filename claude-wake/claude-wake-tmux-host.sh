#!/bin/bash
# claude-wake 的 tmux host server 保活脚本。
#
# 为什么需要它：claude --remote-control 在 tmux 里跑；而 tmux server 由【谁、在什么上下文】
# 起的，决定了里面 claude 的生死。LaunchAgent（守护进程）亲自起的 server 处在 launchd
# bootstrap 受限上下文里 —— 里面 claude 启动会卡死（子进程拿不到用户 GUI 会话的 Mach 服务，
# unix socket 无对端、主线程 cond_wait 干等），连 tmux 客户端命令也卡。实测：在【用户 GUI
# 会话】上下文里起好的 server，wake 挂上去就正常。
#
# 所以：这个脚本由【登录项】（loginwindow 在 Aqua GUI 会话里拉起，上下文是对的）在登录时
# 跑一次，起一个常驻 host server 并用一个永不退出的 _host 会话保活；wake.sh 只往它挂会话、
# 绝不自己起 server。
set -uo pipefail
export TMUX_TMPDIR="${WAKE_TMUX_TMPDIR:-/tmp}"
SOCK="${WAKE_TMUX_SOCK:-claude-wake}"
TM="$(command -v tmux || echo /opt/homebrew/bin/tmux)"

# 已在跑就不重复起
if "$TM" -L "$SOCK" has-session -t _host 2>/dev/null; then
  echo "[claude-wake-host] host server 已在跑"
  exit 0
fi
# 起一个 detached 的永久会话来保活整个 server（sleep 循环，不退出）
"$TM" -L "$SOCK" new-session -d -s _host 'while :; do sleep 86400; done'
echo "[claude-wake-host] 起好了 host server（socket=$SOCK, TMUX_TMPDIR=$TMUX_TMPDIR）"
