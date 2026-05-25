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

#### 安全加固（推荐，长期使用一定要做）

上面清单是"最小可用"配置，便利但攻击面大。下面是每一步的加固版本，按威胁模型对应。

**A. SSH key 加 passphrase + macOS Keychain**

清单第 6 步用 `-N ""` 空 passphrase ——任一设备用户态被入侵 → 攻击者直接拷走 `~/.ssh/id_ed25519` 横向移动到对端。强烈建议改用：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519       # 不带 -N，交互式输 passphrase
ssh-add --apple-use-keychain ~/.ssh/id_ed25519   # 存到 macOS Keychain
```

`--apple-use-keychain` 让 passphrase 落进 login keychain，登录用户后 ssh-agent 自动解锁。desktop 的 ssh2 lib 走 `SSH_AUTH_SOCK` 拿 key（ASAR 里有相关处理），不需要交互输 passphrase。

威胁差别：磁盘镜像被偷 → 加固版 key 仍受 passphrase 保护；裸盘上 `id_ed25519` 直接能用。

**B. sshd 关密码登录 + 限定用户 + 限定来源**

清单第 4 步打开 Remote Login 默认允许 "All users" + 接受密码登录。攻击者通过 Tailscale 拿到内网访问后，可暴力破解密码。

```bash
# /etc/ssh/sshd_config.d/local.conf （新建文件，不动主 config，升级 macOS 不会被覆盖）
sudo tee /etc/ssh/sshd_config.d/local.conf <<'EOF'
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers bobby
EOF

sudo launchctl kickstart -k system/com.openssh.sshd
```

并在 System Settings → Sharing → Remote Login 里把 "Allow access for" 改成 "Only these users" → 只勾自己账号。

确认密码登录已关：从别的机器跑 `ssh -o PreferredAuthentications=password bobby@<host>`，期望立刻被拒。

**C. Tailscale ACL 限定哪些设备能进**

即便 sshd 只接受 key auth，被偷 key 的设备仍能从 Tailscale 网络任意机器进。在 [Tailscale admin → Access Controls](https://login.tailscale.com/admin/acls) 加规则把 SSH (port 22) 限定到自己已知的设备 tag：

```jsonc
{
  "tagOwners": { "tag:mine": ["bobby@..."] },
  "acls": [
    // 只有 tag:mine 的设备能 ssh 进其他 tag:mine 设备
    { "action": "accept", "src": ["tag:mine"], "dst": ["tag:mine:22"] }
  ]
}
```

然后给 MBP / mini 打 `tag:mine` tag。手机 / 临时设备进 Tailscale 也连不上 sshd。

**D. 带外验证 host key fingerprint**

清单第 5 步用 `ssh-keyscan` 一把梭拉 host key —— 如果首次连接时**已经**有 MITM 攻击者占位，你拿到的就是攻击者的 key，写进 known_hosts 等于自己授信中间人。

正确做法：从对端机器物理/带外渠道拿 fingerprint，本机比对：

```bash
# 在对端机器（要被 ssh 的那台）跑
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# 输出形如: 256 SHA256:nc0zKC648+22ZmOAu4MeLKchFQ8FNQcXqvsHbWWdpV4 ...

# 在本机 ssh-keyscan 后比对
ssh-keyscan <对端 host> 2>/dev/null | ssh-keygen -lf -
# 两边 SHA256 必须完全一致才能信任，再 >> known_hosts
```

Tailscale 链路自身 WG 加密 + 设备身份验证 → 中间人攻击窗口实际很小；但如果你 SSH 也走公网 / IPv4，这步是必需的。

**E. `.zshenv` 的代理 env 是攻击面**

清单第 3 步把 `HTTPS_PROXY` 注入所有 SSH session —— 攻击者拿到 ssh 后能通过 Surge 代理把外发流量转发到非预期出口、绕过本地防火墙、复用代理出口资源。

如果担心这层，把 `.zshenv` 改成只在**已知 client IP** 时注入：

```bash
# 只为 Tailscale 网段（100.x.x.x）进来的 SSH session 注入代理
if [ -n "$SSH_CONNECTION" ]; then
  client_ip="${SSH_CONNECTION%% *}"
  case "$client_ip" in
    100.*) export HTTPS_PROXY=http://127.0.0.1:6152
           export HTTP_PROXY=http://127.0.0.1:6152
           export NO_PROXY=localhost,127.0.0.1 ;;
  esac
fi
```

非 Tailscale 来源的 SSH 拿不到 proxy env，外发只能走机器真实出口（也就连不通 anthropic API），自然阻断该攻击路径。

**F. 不要把 ssh key / 代理配置 commit 进仓库**

`~/.ssh/`、`~/.zshenv`、`/etc/ssh/sshd_config.d/local.conf` 这些**绝对**不要 commit 到 mac-launchd 或任何 git 仓库。换机器恢复时手动改，或者用 dotfiles 私有仓库（带加密）单独管。本仓库只放无 secret 的 launchd plist / 脚本。

---

**威胁模型小结**：默认清单假设你完全信任 Tailscale 网络 + 两台 mac 用户态没被入侵。生产长期跑至少做 A + B，重视隐私加 C，公网 SSH 加 D，对 SSH 横向移动敏感加 E。F 是任何情况都必须遵守的红线。
