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
# - 去重基准是 "系统当前 SleepDisabled 实际值", 不是内存里上次写入值. 因为
#   macOS 在某些 sleep/wake 周期后会把 SleepDisabled 重置回 0, 若按内存 last
#   去重, daemon 会自以为 "已经写过 1" 而再也不补, 导致合盖照常 Clamshell Sleep
#   断网. 按实际值去重既能避免稳态反复刷写, 又能在系统漂移时即时纠错.
# - 1s 粒度是为了覆盖 "插电后立刻合盖" 场景: 必须在合盖触发 sleep transition
#   之前把 disablesleep 设为 1, 否则机器会进入 sleep, AC 也救不回来.

set -u

INTERVAL=1

current_target() {
    if /usr/bin/pmset -g ps | /usr/bin/head -1 | /usr/bin/grep -q 'AC Power'; then
        echo 1
    else
        echo 0
    fi
}

current_actual() {
    /usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/{print $2; exit}'
}

apply() {
    local target actual
    target=$(current_target)
    actual=$(current_actual)
    if [ "$target" != "$actual" ]; then
        /usr/bin/pmset -a disablesleep "$target"
        if [ "$target" = "1" ]; then
            echo "$(date '+%F %T') AC      -> disablesleep 1 (was $actual)"
        else
            echo "$(date '+%F %T') Battery -> disablesleep 0 (was $actual)"
        fi
    fi
}

apply
while true; do
    /bin/sleep "$INTERVAL"
    apply
done
