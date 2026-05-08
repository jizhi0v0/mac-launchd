#!/bin/bash
# 根据电源状态切换 disablesleep:
#   AC      -> 1 (合盖不睡, 远程稳定)
#   Battery -> 0 (合盖正常睡, 防止塞包过热)

apply() {
    if /usr/bin/pmset -g ps | /usr/bin/head -1 | /usr/bin/grep -q 'AC Power'; then
        /usr/bin/pmset -a disablesleep 1
        echo "$(date '+%F %T') AC      -> disablesleep 1"
    else
        /usr/bin/pmset -a disablesleep 0
        echo "$(date '+%F %T') Battery -> disablesleep 0"
    fi
}

apply

while /usr/bin/notifyutil -1 -w com.apple.system.powersources.source >/dev/null 2>&1; do
    sleep 1
    apply
done
