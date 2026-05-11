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
