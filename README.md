# mac-launchd

个人 Mac 上的 LaunchDaemon 集合，用于在系统升级/换机后快速恢复习惯配置。

每个子目录是一个独立的 daemon，自带 `install.sh` / `uninstall.sh`。

## 当前列表

### disablesleep-toggle

根据电源状态自动切换 `pmset disablesleep`：

- 插电（AC）→ `disablesleep 1`，合盖不睡，远程控制不断连
- 拔电（Battery）→ `disablesleep 0`，合盖正常睡，防止塞包过热

订阅 darwin notification `com.apple.system.powersources.source`，电源切换时秒级响应。

```bash
cd disablesleep-toggle
./install.sh
```

日志：`/var/log/disablesleep-toggle.log`
