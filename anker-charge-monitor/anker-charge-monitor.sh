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
    "${ext:-?}" "${charging:-?}" "${amp:-?}" "${instamp:-?}" "${volt:-?}" \
    "${ncr:-?}" "${cc:-?}" "${watts:-?}" "${avolt:-?}" "${acur:-?}" "${adesc:-?}"
}

# ── 系统通知:daemon 以 root 跑,需切到当前登录用户的 GUI 会话才能弹出 ──────
notify() {  # notify <title> <message>
  [ "$NOTIFY" = "1" ] || return 0
  local uid user
  uid=$(stat -f%u /dev/console 2>/dev/null)
  user=$(stat -f%Su /dev/console 2>/dev/null)
  # 登录界面 / 无人登录时 console 属 root,弹不出 GUI 通知,跳过(日志已记)
  [ -z "$uid" ] || [ "$uid" = "0" ] || [ "$user" = "root" ] && return 0
  local msg="${2//\"/\\\"}"  # 转义双引号,防 AppleScript 注入/语法错
  local title="${1//\"/\\\"}"
  launchctl asuser "$uid" sudo -u "$user" \
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"$NOTIFY_SOUND\"" \
    >/dev/null 2>&1 || true
}

read_ext() {  # 仅读 ExternalConnected,高频轮询用,尽量轻
  ioreg -rn AppleSmartBattery 2>/dev/null | sed -n 's/.*"ExternalConnected" = \([A-Za-z]*\).*/\1/p' | head -1
}

# ── pslog 事件路(后台子进程)────────────────────────────────────────────
pslog_watch() {
  # 把 powerd 的电源源切换打上我们的时间戳记进同一个日志
  pmset -g pslog 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"Now drawing from"*)
        emit PSLOG "${line#*Now drawing from }"
        ;;
    esac
  done
}

# ── 主流程 ──────────────────────────────────────────────────────────────
emit START "monitor up (poll=${POLL_INTERVAL}s, heartbeat=${HEARTBEAT_SEC}s) :: $(snapshot)"

pslog_watch &
PSLOG_PID=$!
trap 'kill "$PSLOG_PID" 2>/dev/null; emit STOP "monitor down"; exit 0' TERM INT

prev_ext="$(read_ext)"
last_hb=$(date +%s)
loop_count=0

while true; do
  cur_ext="$(read_ext)"
  if [ -n "$cur_ext" ] && [ "$cur_ext" != "$prev_ext" ]; then
    if [ "$cur_ext" = "No" ]; then
      emit DISCONNECT "ExternalConnected ${prev_ext:-?} -> No :: $(snapshot)"
      notify "⚡ 充电瞬断" "$(ts) 充电头断开(ExternalConnected→No)"
    else
      emit RECONNECT  "ExternalConnected ${prev_ext:-?} -> ${cur_ext} :: $(snapshot)"
    fi
    prev_ext="$cur_ext"
  fi

  # 心跳 + 轮转检查(每 ~20 次轮询查一次轮转,避免每次 stat)
  loop_count=$((loop_count+1))
  now=$(date +%s)
  if [ $((now - last_hb)) -ge "$HEARTBEAT_SEC" ]; then
    emit HEARTBEAT "$(snapshot)"
    last_hb=$now
  fi
  [ $((loop_count % 20)) -eq 0 ] && rotate_if_needed

  sleep "$POLL_INTERVAL"
done
