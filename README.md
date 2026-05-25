# mac-launchd

个人 Mac 上的 LaunchDaemon 集合，用于在系统升级/换机后快速恢复习惯配置。

每个子目录是一个独立的 daemon，自带 `install.sh` / `uninstall.sh`。

## 当前列表

### disablesleep-toggle

根据电源状态自动切换 `pmset disablesleep`：

- 插电（AC）→ `disablesleep 1`，合盖不睡，远程控制不断连
- 拔电（Battery）→ `disablesleep 0`，合盖正常睡，防止塞包过热

1 秒轮询电源状态，仅在状态变化时写 `pmset`，避免反复刷写 IOPMrootDomain 触发网络栈抖动。

```bash
cd disablesleep-toggle
./install.sh
```

日志：`/var/log/disablesleep-toggle.log`

### offline-translator

后台跑 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的 `llama-server`，加载腾讯混元 [HY-MT1.5-1.8B](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF) 翻译模型，监听 `127.0.0.1:8110`，提供离线 OpenAI 兼容翻译 API。

依赖：`brew install llama.cpp`

```bash
cd offline-translator
./install.sh
```

首次启动会从 HuggingFace 拉取模型（~2GB），后续直接用本地缓存。日志：`/tmp/hy-mt-llama-server.{out,err}.log`。

### claude-ssh-prep

预热 Claude desktop 的 SSH remote agent + claude CLI zst。desktop 通过 SSH 远程到这台机器时，会要求拉 `claude-ssh.zst`（2MB）+ `claude.zst`（42MB）。其中 CLI zst 是 desktop 命令 remote-side server 自己去 fetch 的；如果这台 mac 直连 `downloads.claude.ai` 不稳（国际段烂、走 DERP / Surge ponte 大文件容易断），就会卡在 "Configuring machine..."。

LaunchAgent 监听 `/Applications/Claude.app/Contents/Resources/app.asar`（desktop 升级会替换它）—— 一变化就重新预热：

- 读 ASAR 里硬编码的两个 manifest 拿 hash + version + 各平台 checksum
- 走系统 HTTPS 代理（`scutil --proxy`），稳定拉两个 zst
- 校验 sha256，解压 SSH agent → `~/.claude/remote/srv/<hash>/server`；CLI zst 原样落 `~/.claude/remote/ccd-cli/<version>.zst`
- 文件已存在且 checksum 对 → 直接 skip，零成本

```bash
cd claude-ssh-prep
./install.sh
```

依赖：`brew install zstd`。日志：`/tmp/claude-ssh-prep.{out,err}.log`。同一份代码两台 mac 都装就构成对称 mesh，谁也不依赖谁。
