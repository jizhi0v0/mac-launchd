#!/bin/bash
# 根据电源状态切换 disablesleep:
#   AC      -> 1 (合盖不睡, 远程稳定)
#   Battery -> 0 (合盖正常睡, 防止塞包过热)
#
# 设计:
# - 长驻进程 + 1s 轮询. 早期版本用 notifyutil -1 -w 订阅 darwin notification,
#   但该调用在本机环境立即返回非 0, 导致 while 立刻退出, 配合 launchd KeepAlive
#   每 10s 重启一次脚本, 每次都重写 pmset, 高频 IOPMrootDomain 状态变更触发了
#   网络栈抖动, 远程控制 (ToDesk) 长连接因此被反复打断.
# - 仅在状态变化时调用 pmset, 避免无谓刷写. 状态去重后 1s 轮询零开销.
# - 1s 粒度是为了覆盖 "插电后立刻合盖" 场景: 必须在合盖触发 sleep transition
#   之前把 disablesleep 设为 1, 否则机器会进入 sleep, AC 也救不回来.

set -u

INTERVAL=1
last=""

current_target() {
    if /usr/bin/pmset -g ps | /usr/bin/head -1 | /usr/bin/grep -q 'AC Power'; then
        echo 1
    else
        echo 0
    fi
}

apply() {
    local target
    target=$(current_target)
    if [ "$target" != "$last" ]; then
        /usr/bin/pmset -a disablesleep "$target"
        if [ "$target" = "1" ]; then
            echo "$(date '+%F %T') AC      -> disablesleep 1"
        else
            echo "$(date '+%F %T') Battery -> disablesleep 0"
        fi
        last="$target"
    fi
}

apply
while true; do
    /bin/sleep "$INTERVAL"
    apply
done
