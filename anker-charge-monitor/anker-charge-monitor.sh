#!/bin/bash
# 监控充电头(安克 PD)偶现瞬断:屏幕闪黑的根因是 ExternalConnected 翻转 / 供电源切换。
# 两路互补采集:
#   1) pmset -g pslog —— 事件驱动(IOPSNotificationCreateRunLoopSource),powerd 自己的视角
#   2) 高频轮询 ioreg ExternalConnected —— 兜底事件被 powerd 去抖合并掉的极短 blip
# 任一路检测到状态翻转,立即抓一次富快照(电流 / NotChargingReason / 适配器档位)。
set -uo pipefail

# ── 可调参数(plist 里用 EnvironmentVariables 覆盖)──────────────────────
LOG="${ACM_LOG:-/var/log/anker-charge-monitor.log}"
POLL_INTERVAL="${ACM_POLL_INTERVAL:-0.5}"   # 高频轮询间隔(秒)
HEARTBEAT_SEC="${ACM_HEARTBEAT_SEC:-3600}"  # 心跳:每隔多久记一条"仍在运行+当前状态"
MAX_BYTES="${ACM_MAX_BYTES:-10485760}"      # 单文件 10MB 触发轮转
ROTATE_KEEP="${ACM_ROTATE_KEEP:-3}"         # 保留 .1 .2 .3
NOTIFY="${ACM_NOTIFY:-1}"                    # 1=断开时弹系统通知,0=只记日志
NOTIFY_SOUND="${ACM_NOTIFY_SOUND:-Funk}"    # 通知声音(/System/Library/Sounds 里的名字)
NOTIFY_COOLDOWN="${ACM_NOTIFY_COOLDOWN:-30}" # 两次弹窗最小间隔(秒),防抖动轰炸;日志不受影响
# 运行时文件放 /var/run(root-only,非世界可写,避开 /tmp 符号链接攻击面)
RUN_DIR="${ACM_RUN_DIR:-/var/run}"
PSLOG_PIDFILE="$RUN_DIR/anker-charge-monitor.pmset.pid"
FIFO="$RUN_DIR/anker-charge-monitor.pslog.fifo"

# ── 毫秒时间戳(BSD date 无 %N,用 perl)──────────────────────────────────
ts() {
  perl -MPOSIX -MTime::HiRes=time -e \
    'my $t=time; printf "%s.%03d%s", strftime("%Y-%m-%dT%H:%M:%S",localtime($t)), int(($t-int($t))*1000), strftime("%z",localtime($t));'
}

emit() {  # emit <tag> <message...>
  local tag="$1"; shift
  printf '%s\t%s\t%s\n' "$(ts)" "$tag" "$*" >> "$LOG"
}

rotate_if_needed() {
  local sz
  sz=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
  [ "$sz" -lt "$MAX_BYTES" ] && return 0
  local i
  for ((i=ROTATE_KEEP-1; i>=1; i--)); do
    [ -f "$LOG.$i" ] && mv -f "$LOG.$i" "$LOG.$((i+1))"
  done
  mv -f "$LOG" "$LOG.1"
  emit ROTATE "log rotated, prev -> $LOG.1"
}

# 电流是有符号值,放电时 ioreg 按 64 位无符号打印(如 18446744073709549736),转回有符号
to_signed() {
  local v="$1"
  case "$v" in ''|*[!0-9-]*) printf '%s' "$v"; return;; esac   # 空 / 已带负号 / 非纯数字,原样
  if [ "${#v}" -ge 19 ]; then
    bc <<< "$v - 18446744073709551616"                          # 大数=两补码负数,减 2^64
  else
    printf '%s' "$v"
  fi
}

# ── 富快照:断开/恢复那一刻的现场 ────────────────────────────────────────
snapshot() {  # 单次 ioreg,提取关键字段
  local raw
  raw=$(ioreg -rn AppleSmartBattery 2>/dev/null)
  local ext charging amp instamp volt
  ext=$(printf '%s' "$raw"     | sed -n 's/.*"ExternalConnected" = \([A-Za-z]*\).*/\1/p' | head -1)
  charging=$(printf '%s' "$raw"| sed -n 's/.*"IsCharging" = \([A-Za-z]*\).*/\1/p'        | head -1)
  amp=$(printf '%s' "$raw"     | sed -n 's/.*"Amperage" = \(-*[0-9]*\).*/\1/p'           | head -1)
  instamp=$(printf '%s' "$raw" | sed -n 's/.*"InstantAmperage" = \(-*[0-9]*\).*/\1/p'    | head -1)
  volt=$(printf '%s' "$raw"    | sed -n 's/.*"Voltage" = \([0-9]*\).*/\1/p'              | head -1)
  # ChargerData 内的充电诊断
  local ncr cc
  ncr=$(printf '%s' "$raw"     | sed -n 's/.*"NotChargingReason"=\([0-9]*\).*/\1/p'      | head -1)
  cc=$(printf '%s' "$raw"      | sed -n 's/.*"ChargingCurrent"=\([0-9]*\).*/\1/p'        | head -1)
  # 适配器档位(瞬断后 PD 重新协商会变)
  local watts acur avolt adesc
  watts=$(printf '%s' "$raw"   | sed -n 's/.*"AdapterDetails" = {[^}]*"Watts"=\([0-9]*\).*/\1/p'   | head -1)
  acur=$(printf '%s' "$raw"    | sed -n 's/.*"AdapterDetails".*"Current"=\([0-9]*\).*/\1/p'        | head -1)
  avolt=$(printf '%s' "$raw"   | sed -n 's/.*"AdapterDetails".*"AdapterVoltage"=\([0-9]*\).*/\1/p' | head -1)
  adesc=$(printf '%s' "$raw"   | sed -n 's/.*"AdapterDetails".*"Description"="\([^"]*\)".*/\1/p'   | head -1)
  printf 'ext=%s charging=%s amp=%s instAmp=%s battV=%s | NotChargingReason=%s chargingCurrent=%s | adapter=%sW/%smV/%smA(%s)' \
    "${ext:-?}" "${charging:-?}" "$(to_signed "${amp:-?}")" "$(to_signed "${instamp:-?}")" "${volt:-?}" \
    "${ncr:-?}" "${cc:-?}" "${watts:-?}" "${avolt:-?}" "${acur:-?}" "${adesc:-?}"
}

# ── 系统通知:daemon 以 root 跑,需切到当前登录用户的 GUI 会话才能弹出 ──────
last_notify=-99999   # 负哨兵:保证开机后首次断开一定弹(不被冷却窗口吞)
notify() {  # notify <title> <message>
  [ "$NOTIFY" = "1" ] || return 0
  # 冷却:抖动时只弹一次,避免几秒一弹轰炸(DISCONNECT 日志不受影响,照记)
  if [ $((SECONDS - last_notify)) -lt "$NOTIFY_COOLDOWN" ]; then return 0; fi
  local uid user
  uid=$(stat -f%u /dev/console 2>/dev/null)
  user=$(stat -f%Su /dev/console 2>/dev/null)
  # 登录界面 / 无人登录时 console 属 root,弹不出 GUI 通知,跳过(日志已记)
  if [ -z "$uid" ] || [ "$uid" = "0" ] || [ "$user" = "root" ]; then return 0; fi
  # 内容是脚本自身生成的固定文本,这里仍转义反斜杠和双引号防 AppleScript 语法破坏
  local title="${1//\\/\\\\}"; title="${title//\"/\\\"}"
  local msg="${2//\\/\\\\}";   msg="${msg//\"/\\\"}"
  launchctl asuser "$uid" sudo -u "$user" \
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"$NOTIFY_SOUND\"" \
    >/dev/null 2>&1 || true
  last_notify=$SECONDS
}

read_ext() {  # 仅读 ExternalConnected,高频轮询用,尽量轻
  ioreg -rn AppleSmartBattery 2>/dev/null | sed -n 's/.*"ExternalConnected" = \([A-Za-z]*\).*/\1/p' | head -1
}

# 启动时清掉上一实例(主脚本崩溃)可能遗留的 pmset 孤儿,避免长期累积
cleanup_stale_pmset() {
  [ -f "$PSLOG_PIDFILE" ] || return 0
  local old; old=$(cat "$PSLOG_PIDFILE" 2>/dev/null)
  case "$old" in
    [0-9]*) ps -p "$old" -o command= 2>/dev/null | grep -q "pmset -g pslog" && kill "$old" 2>/dev/null ;;
  esac
}

# ── pslog 事件路(后台 supervisor:pmset 退出/被系统回收时自动重启)──────────
# 经 FIFO 拿到 pmset 的真实 PID 写入 pidfile,退出时按精确 PID 回收(不受 reparent 影响)
pslog_supervisor() {
  [ -p "$FIFO" ] || { rm -f "$FIFO"; mkfifo -m 600 "$FIFO" 2>/dev/null; }
  while true; do
    pmset -g pslog > "$FIFO" 2>/dev/null &   # $! 即 pmset 真实 PID
    echo "$!" > "$PSLOG_PIDFILE"
    while IFS= read -r line; do
      case "$line" in
        *"Now drawing from"*)
          emit PSLOG "${line#*Now drawing from }"
          ;;
      esac
    done < "$FIFO"
    # FIFO 读到 EOF = pmset 退出(崩溃 / 睡眠唤醒被回收等),重启继续监听
    emit WARN "pslog 流中断,2s 后重启 powerd 事件监听"
    sleep 2
  done
}

# ── 主流程 ──────────────────────────────────────────────────────────────
emit START "monitor up (poll=${POLL_INTERVAL}s, heartbeat=${HEARTBEAT_SEC}s) :: $(snapshot)"

cleanup_stale_pmset
pslog_supervisor &
SUPERVISOR_PID=$!
# 退出:停 supervisor + 按 pidfile 精确杀 pmset(reparent 也能杀掉)+ 清运行时文件
shutdown() {
  kill "$SUPERVISOR_PID" 2>/dev/null
  [ -f "$PSLOG_PIDFILE" ] && kill "$(cat "$PSLOG_PIDFILE" 2>/dev/null)" 2>/dev/null
  rm -f "$FIFO" "$PSLOG_PIDFILE"
  emit STOP "monitor down"
  exit 0
}
trap shutdown TERM INT

prev_ext="$(read_ext)"
last_hb=$SECONDS                  # bash 内建,免每轮 fork date
loop_count=0

while true; do
  cur_ext="$(read_ext)"
  # 仅在两端都拿到有效读数、且确实翻转时才算事件(避免首次/瞬时空读产生假事件)
  if [ -n "$cur_ext" ] && [ -n "$prev_ext" ] && [ "$cur_ext" != "$prev_ext" ]; then
    if [ "$cur_ext" = "No" ]; then
      emit DISCONNECT "ExternalConnected ${prev_ext} -> No :: $(snapshot)"
      notify "⚡ 充电瞬断" "$(ts) 充电头断开(ExternalConnected→No)"
    else
      emit RECONNECT  "ExternalConnected ${prev_ext} -> ${cur_ext} :: $(snapshot)"
    fi
  fi
  [ -n "$cur_ext" ] && prev_ext="$cur_ext"   # 空读不覆盖上一次有效状态

  # 心跳 + 轮转检查(每 ~20 次轮询查一次轮转,避免每次 stat)
  loop_count=$((loop_count+1))
  if [ $((SECONDS - last_hb)) -ge "$HEARTBEAT_SEC" ]; then
    emit HEARTBEAT "$(snapshot)"
    last_hb=$SECONDS
  fi
  [ $((loop_count % 20)) -eq 0 ] && rotate_if_needed

  sleep "$POLL_INTERVAL"
done
