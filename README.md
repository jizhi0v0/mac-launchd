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

预热 Claude desktop 的 SSH remote agent + claude CLI binary。desktop 通过 SSH 远程到这台机器时，会要求 server binary（5.9MB）+ claude CLI（213MB 解压后）。其中 CLI 是 desktop 命令 remote-side server 自己去 fetch 的；如果这台 mac 直连 `downloads.claude.ai` 不稳（国际段烂、走 DERP / Surge ponte 大文件容易断），会卡在 "Configuring machine..."。

LaunchAgent 监听 `/Applications/Claude.app/Contents/Resources/app.asar`（desktop 升级会替换它）—— 一变化就重新预热：

- 读 ASAR 里硬编码的两个 manifest 拿 hash + version + 各平台 checksum
- 走系统 HTTPS 代理（`scutil --proxy`），稳定拉两个 zst
- 校验 sha256，解压：SSH agent → `~/.claude/remote/srv/<hash>/server`；CLI 双份 `~/.claude/remote/ccd-cli/<version>.zst`（cache）+ `~/.claude/remote/ccd-cli/<version>`（无扩展名 binary，server 实际 spawn 这个）
- 文件已存在且 checksum 对 → 直接 skip，零成本

```bash
cd claude-ssh-prep
./install.sh
```

依赖：`brew install zstd`。日志：`/tmp/claude-ssh-prep.{out,err}.log`。同一份代码两台 mac 都装就构成对称 mesh，谁也不依赖谁。

#### 换新机器 / 二台 mac 全栈部署清单

让 Claude desktop 在两台 mac 之间互相做 remote SSH 跑稳的完整步骤（按顺序，每一步都是必需）：

1. **装 zstd**（prep 脚本依赖）
   ```bash
   brew install zstd
   ```

2. **装 prep 模块**
   ```bash
   git clone https://github.com/jizhi0v0/mac-launchd.git ~/Developer/github/mac-launchd
   cd ~/Developer/github/mac-launchd/claude-ssh-prep
   ./install.sh
   ```
   首次跑会拉两个 zst 解压；后续 desktop 升级 → app.asar 变 → LaunchAgent 自动 trigger。

3. **配 sshd shell 的代理 env**（不然 server spawn CLI 时 anthropic API 鉴权 403 "Request not allowed"）

   `~/.zshenv` 追加（替换端口为你的实际代理）：
   ```bash
   if [ -n "$SSH_CONNECTION" ]; then
     export HTTPS_PROXY=http://127.0.0.1:6152
     export HTTP_PROXY=http://127.0.0.1:6152
     export NO_PROXY=localhost,127.0.0.1
   fi
   ```
   `SSH_CONNECTION` 守护让本机交互 shell 不受影响，只有 sshd session 拿到 proxy env。

4. **开 Remote Login** —— System Settings → General → Sharing → Remote Login 打开（命令行 `sudo systemsetup -setremotelogin on` 在 macOS 14+ 要 Full Disk Access）

5. **手动写对端 host key 到 known_hosts**（desktop 的 ssh client 用 `ssh-keygen -F` 查 known_hosts，**不读** ssh_configs.json 里的 trustedHosts UI 状态——那只是显示用）
   ```bash
   # 双向都做：在 mac A 上写 mac B 的 key，反之亦然
   ssh-keyscan <对端 host> >> ~/.ssh/known_hosts
   ssh-keygen -F <对端 host>   # 验证能找到
   ```

6. **生成 + 互拷 ssh key**（desktop 不缓存密码，必须 key auth）
   ```bash
   # 如果没 key 先生成（-N "" 空 passphrase；desktop ssh2 lib 不能交互输 passphrase，
   # 想要 passphrase 保护需配合 ssh-agent + macOS Keychain）
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
   ssh-copy-id bobby@<对端 host>
   ```

7. **MBP / mini desktop 各自登录账号**，然后在 desktop 的 SSH session UI 里填对端 host，发起一次连接验证。

#### 已知坑（按踩到顺序）

| 现象 | 真正原因 | 修法 |
|---|---|---|
| install.sh 报 installed，但 LaunchAgent 日志说 "需要 zstd: brew install zstd" | LaunchAgent 子进程 PATH 默认 `/usr/bin:/bin:/usr/sbin:/sbin`，找不到 `/opt/homebrew/bin/zstd`；install.sh 在交互 shell 里跑能找到，骗过早期检查 | 脚本顶部 `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"` 兜底（已加） |
| Configuring machine 秒过，但 send message 立刻 `fork/exec ccd-cli/<version>: no such file or directory` | server 期望的是 `ccd-cli/<version>` 无扩展名 binary（strings 文档：`Required CLI version (filename under --cli-dir)`），但 prep 只预热了 `.zst`；server install 看到 zst checksum 对就 short-circuit 跳过解压 | prep 脚本同时落 zst（cache）+ 解压后 binary（已加） |
| Configuring machine 过，send message 弹 "Authentication failed. API Error: 403 Request not allowed" | 远端 CLI binary 是 Go 程序，只读 `HTTPS_PROXY` env，不读系统代理设置；sshd 启的子进程 env 是裸的，没有 PROXY 变量，CLI 直连 anthropic 被边缘判定不允许区域 | `.zshenv` 加 `SSH_CONNECTION` 守护的 proxy export（见上）|
| desktop 连接报 "Host denied (verification failed)"，即便 ssh_configs.json 里 trustedHosts 已记 | desktop 真正用 `ssh-keygen -F <host>` 查 OpenSSH known_hosts，trustedHosts 只是 UI 上的 "我点过 trust" 标记，跟底层 verifier 无关；如果 known_hosts 没 entry 就 reject | `ssh-keyscan <host> >> ~/.ssh/known_hosts`（见上）|
| desktop 每次重连都问密码 | desktop 故意不缓存密码（安全策略），只能走 ssh key auth | 双向 `ssh-copy-id`（见上）|
| 之前 SFTP 推 server 时下到一半 DERP 链路断了，留个 partial server (917KB / 完整 5.9MB)，desktop 后续 reattach 时 `test -x` 过但 `--version` exec 直接挂掉 | desktop 端 SFTP 上传**不**做完整性校验，半成品文件留在 srv/ 永久挂着 | prep 脚本预热完整 binary 后用 atomic mv，desktop 永远看不到半写状态；如果碰到老遗留，手动 `rm ~/.claude/remote/srv/<hash>/server` 重新跑 prep |
| `ssh user@host` 在终端能通，desktop UI 还报 Host denied | 同上 known_hosts 问题；终端 ssh 接受 fingerprint 后**应该**写 known_hosts，但实测有时不写（路径配置异常 / UserKnownHostsFile 不对） | 别相信"我刚才 ssh 进去过了"，老老实实 `ssh-keygen -F <host>` 验证 entry 真在 |
