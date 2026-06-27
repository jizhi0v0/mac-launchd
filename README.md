# mac-launchd

个人 Mac 的 LaunchDaemon / LaunchAgent 集合,系统升级或换机后快速恢复习惯配置。每个子目录是一个独立模块,自带 `install.sh` / `uninstall.sh`。

| 模块 | 作用 | 类型 | 日志 |
|---|---|---|---|
| [disablesleep-toggle](#disablesleep-toggle) | 插电合盖不睡 / 拔电正常睡 | Daemon | `/var/log/disablesleep-toggle.log` |
| [anker-charge-monitor](#anker-charge-monitor) | 记录充电瞬断 + 断开通知 | Daemon | `/var/log/anker-charge-monitor.log` |
| [offline-translator](#offline-translator) | 本地 MLX 离线翻译 API | Agent | `/tmp/offline-translator.*.log` |
| [claude-ssh-prep](#claude-ssh-prep) | 预热 Claude desktop 的 SSH remote agent | Agent | `/tmp/claude-ssh-prep.*.log` |
| [crash-notify](#crash-notify) | 监听崩溃报告 + 私有 dump,新崩溃弹本地横幅 | Agent | `~/Library/Logs/crash-notify.log` |
| [claude-wake](#claude-wake) | 远程唤醒一个全新 claude RC 会话(远控逃生舱) | Agent | `/tmp/claude-wake.*.log` |

安装统一:`cd <模块> && ./install.sh`(Daemon 装到 `/Library/LaunchDaemons`,会要 sudo)。

---

## disablesleep-toggle

按电源状态自动切 `pmset disablesleep`:插电(AC)→ `1` 合盖不睡、远控不断连;拔电(Battery)→ `0` 合盖正常睡、防塞包过热。1 秒轮询,仅状态变化时写,避免反复刷 IOPMrootDomain 触发网络栈抖动。

---

## anker-charge-monitor

监控充电头(安克 PD)偶现**瞬断** —— 屏幕闪黑的根因是供电源翻转(`ExternalConnected` Yes↔No)。两路互补采集:`pmset -g pslog` 事件流(powerd 视角)+ `ioreg ExternalConnected` 0.5s 高频轮询兜底;任一路检测到翻转,立即抓富快照(有符号电流 / `NotChargingReason` / PD 适配器档位)写日志,并弹系统通知(带声音 + 冷却防轰炸)。LaunchDaemon,登录界面 / 锁屏也照记。

```
…DISCONNECT  ExternalConnected Yes -> No  :: ext=No  ... adapter=3W/5000mV/500mA(usb brick)
…RECONNECT   ExternalConnected No  -> Yes :: ext=Yes ... adapter=140W/28000mV/4990mA(pd charger)
```

屏幕再闪黑时,对一下日志同一时刻有没有 `DISCONNECT`、PD 档位掉到了哪一级,即可坐实是不是充电头瞬断。

<details>
<summary>📋 日志 tag / 可调参数 / 已知局限</summary>

**日志 tag**

| tag | 含义 |
|---|---|
| `START` / `STOP` | 监控启停 + 当时快照 |
| `PSLOG` | powerd 事件流报告的供电源切换(`'AC Power'` / `'Battery Power'`) |
| `DISCONNECT` / `RECONNECT` | 轮询检测到 `ExternalConnected` 翻转 + 富快照 |
| `HEARTBEAT` | 周期性"仍在运行 + 当前状态",确认 daemon 活着 |
| `WARN` | pslog 流中断,supervisor 正在重启 |
| `ROTATE` | 日志轮转 |

**可调参数**(plist 里用 `EnvironmentVariables` 覆盖,默认值见脚本头部)

| 变量 | 默认 | 说明 |
|---|---|---|
| `ACM_POLL_INTERVAL` | `0.5` | 轮询间隔(秒),调小提高极短 blip 命中率 |
| `ACM_NOTIFY` | `1` | `0` = 只记日志不弹通知 |
| `ACM_NOTIFY_SOUND` | `Funk` | `/System/Library/Sounds` 里的声音名 |
| `ACM_NOTIFY_COOLDOWN` | `30` | 两次弹窗最小间隔(秒);日志不受影响 |
| `ACM_HEARTBEAT_SEC` | `3600` | 心跳间隔 |
| `ACM_MAX_BYTES` / `ACM_ROTATE_KEEP` | `10MB` / `3` | 日志轮转阈值 / 保留份数 |

常用查看:
```bash
tail -f /var/log/anker-charge-monitor.log
grep -E 'DISCONNECT|RECONNECT' /var/log/anker-charge-monitor.log
```

**长稳设计**:pslog 子进程崩溃 / 睡眠唤醒被回收时由 supervisor 自动重启;经 FIFO + pidfile(`/var/run`,避开 `/tmp` 符号链接攻击面)精确回收 pmset,杜绝孤儿累积;启动时清理上次遗留。

**已知局限**:① 断开+恢复都发生在同一个 0.5s 间隔内、且被 powerd 去抖合并的极短瞬断,两路都可能漏(实测真实断开多持续数秒,当前精度够用)。② 睡眠期间发生并在唤醒前恢复的拔插记不到(那时屏幕本就黑,无"闪黑"症状)。

</details>

---

## offline-translator

后台跑 [MLX](https://github.com/ml-explore/mlx-lm) 的 `mlx_lm.server`,加载腾讯混元 [Hy-MT2-1.8B](https://huggingface.co/tencent/Hy-MT2-1.8B)(**4-bit MLX**)翻译模型,监听 `127.0.0.1:8110`,提供离线 OpenAI 兼容翻译 API。**对外 model 名是中性的 `Hy-MT2-1.8B`**(实为软链 → 当前量化目录 `Hy-MT2-1.8B-mlx-4bit`):与量化解耦,换量化只改软链指向,客户端 model 字段不用动。

为什么从 llama.cpp 换成 MLX:Apple Silicon 上 MLX 走原生 Metal、内存更省,且在用户 GUI 会话里才拿得到 Metal GPU,所以是 **user LaunchAgent**(登录即起)而非 system LaunchDaemon。

为什么用 4-bit(权衡过 8-bit):旧 llama.cpp 是 `HY-MT1.5 Q8_0`(8-bit,~3GB)。MT2 上 4bit/8bit 实测对比——质量差异很小(8bit 仅在网络梗/罕见术语上略好,如"真香"、"dock tile");但**重并发整页翻译**下内存差距明显:**8bit 稳态 ~3.3GB / 峰值 ~5.4GB,4bit 稳态 ~1.3GB / 峰值 ~2.5GB**(峰值大头是并发请求的 KV/计算缓冲,非权重)。综合取 **4-bit**:质量够用、内存省一截、速度还快 ~20-30%(都亚秒)。

> ⚠️ 两个坑:① `mlx_lm.server` 按请求 `model` 字段**动态加载**模型——发未知名会 404、发别的本地目录名会去加载那个。中性软链 + 真目录名(`Hy-MT2-1.8B-mlx-4bit`)同realpath,客户端发中性 id 或旧的 `-mlx-4bit` 名都解析到同一模型、不触发重载。② `mlx-community/*` 等仓是 Xet 存储,`hf`/`snapshot_download` 会卡 0B,故用 curl 直连 `…/resolve/main/<file>`。

依赖 [`uv`](https://github.com/astral-sh/uv)。`./install.sh` 会建独立 venv、装 `mlx-lm`、用 **curl 直连 resolve** 下 4-bit MLX([`jizhiovo/Hy-MT2-1.8B-mlx-4bit`](https://huggingface.co/jizhiovo/Hy-MT2-1.8B-mlx-4bit),~977MB;下不全则回退到从 `tencent/Hy-MT2-1.8B` 本地 `--q-bits 4` 转换)、建中性软链,并清掉旧版 llama.cpp system daemon(需 sudo)。换机 `./install.sh` 一键复现。

---

## claude-ssh-prep

预热 Claude desktop 的 SSH remote agent:desktop 远程到这台机器时需要 server binary(5.9MB)+ CLI(解压后 213MB),直连 `downloads.claude.ai` 不稳时会卡在 "Configuring machine..."。LaunchAgent 监听 `app.asar`(desktop 升级会替换它),一变化就重新预热:读内嵌 manifest 拿 checksum → 走系统代理下载 zst → sha256 校验 → 原子解压落盘;已存在且 checksum 对则 skip。依赖 `brew install zstd`,两台 mac 都装构成对称 mesh。

<details>
<summary>📋 换新机器 / 双 mac 全栈部署清单</summary>

让 Claude desktop 在两台 mac 之间互相做 remote SSH 跑稳的完整步骤(按顺序,每一步都是必需):

1. **装 zstd**(prep 脚本依赖)
   ```bash
   brew install zstd
   ```

2. **装 prep 模块**
   ```bash
   git clone https://github.com/jizhi0v0/mac-launchd.git ~/Developer/github/mac-launchd
   cd ~/Developer/github/mac-launchd/claude-ssh-prep
   ./install.sh
   ```
   首次跑会拉两个 zst 解压;后续 desktop 升级 → app.asar 变 → LaunchAgent 自动 trigger。

3. **配 sshd shell 的代理 env**(不然 server spawn CLI 时 anthropic API 鉴权 403 "Request not allowed")

   `~/.zshenv` 追加(替换端口为你的实际代理):
   ```bash
   if [ -n "$SSH_CONNECTION" ]; then
     export HTTPS_PROXY=http://127.0.0.1:6152
     export HTTP_PROXY=http://127.0.0.1:6152
     export NO_PROXY=localhost,127.0.0.1
   fi
   ```
   `SSH_CONNECTION` 守护让本机交互 shell 不受影响,只有 sshd session 拿到 proxy env。

4. **开 Remote Login** —— System Settings → General → Sharing → Remote Login 打开(命令行 `sudo systemsetup -setremotelogin on` 在 macOS 14+ 要 Full Disk Access)

5. **手动写对端 host key 到 known_hosts**(desktop 的 ssh client 用 `ssh-keygen -F` 查 known_hosts,**不读** ssh_configs.json 里的 trustedHosts UI 状态——那只是显示用)
   ```bash
   # 双向都做:在 mac A 上写 mac B 的 key,反之亦然
   ssh-keyscan <对端 host> >> ~/.ssh/known_hosts
   ssh-keygen -F <对端 host>   # 验证能找到
   ```

6. **ssh key 全套:生成 + 存 Keychain + 推对端 + 配 ssh config**(desktop 不缓存密码,必须 key auth;passphrase + Keychain 是默认配置,攻击面差异见安全加固 A)

   ```bash
   # ① 生成带 passphrase 的 key(交互输 passphrase 两次)
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

   # ② 把 passphrase 存到 macOS Keychain —— ⚠️ 必须在本机桌面 session 跑!
   #    sshd 子 shell 没有桌面 keychain 访问权限,远程 ssh 跑会报 "Could not open a
   #    connection to your authentication agent"。headless 机器用屏幕共享 / 远程桌面进。
   ssh-add --apple-use-keychain ~/.ssh/id_ed25519

   # ③ 把 pubkey 推到对端 —— ⚠️ 必须在步骤 7(关 sshd 密码登录)之前完成!
   #    顺序反了 → 对端不接受密码也不认你 key → 死锁 → 只能远程桌面进对端救援
   ssh-copy-id bobby@<对端 host>

   # ④ 配 ssh config 让 ssh client 走 Keychain(一劳永逸)
   #    ⚠️ 用 "Host *.tail69730a.ts.net" 限定到 Tailscale 网段,不要用 "Host *" 通配,
   #    后者会吃掉 OrbStack 等其它 Host 块的 IdentityFile。
   cat >> ~/.ssh/config <<'EOF'

   Host *.tail69730a.ts.net
     UseKeychain yes
     AddKeysToAgent yes
     IdentityFile ~/.ssh/id_ed25519
   EOF
   chmod 600 ~/.ssh/config
   ```

7. **关 sshd 密码登录**(防止密码被暴力破解;步骤 6 完成、双向 ssh 验证通过后再做)

   ```bash
   sudo tee /etc/ssh/sshd_config.d/local.conf <<'EOF'
   PasswordAuthentication no
   ChallengeResponseAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin no
   AllowUsers bobby
   EOF
   sudo launchctl kickstart -k system/com.openssh.sshd
   ```

   验证:`ssh -o PreferredAuthentications=password bobby@<对端>` 应被拒(`Permission denied (publickey)`)。

8. **MBP / mini desktop 各自登录账号**,然后在 desktop 的 SSH session UI 里填对端 host,发起一次连接验证。

</details>

<details>
<summary>🪤 已知坑(按踩到顺序)</summary>

| 现象 | 真正原因 | 修法 |
|---|---|---|
| install.sh 报 installed,但 LaunchAgent 日志说 "需要 zstd: brew install zstd" | LaunchAgent 子进程 PATH 默认 `/usr/bin:/bin:/usr/sbin:/sbin`,找不到 `/opt/homebrew/bin/zstd`;install.sh 在交互 shell 里跑能找到,骗过早期检查 | 脚本顶部 `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"` 兜底(已加) |
| Configuring machine 秒过,但 send message 立刻 `fork/exec ccd-cli/<version>: no such file or directory` | server 期望的是 `ccd-cli/<version>` 无扩展名 binary(strings 文档:`Required CLI version (filename under --cli-dir)`),但 prep 只预热了 `.zst`;server install 看到 zst checksum 对就 short-circuit 跳过解压 | prep 脚本同时落 zst(cache)+ 解压后 binary(已加) |
| Configuring machine 过,send message 弹 "Authentication failed. API Error: 403 Request not allowed" | 远端 CLI binary 是 Go 程序,只读 `HTTPS_PROXY` env,不读系统代理设置;sshd 启的子进程 env 是裸的,没有 PROXY 变量,CLI 直连 anthropic 被边缘判定不允许区域 | `.zshenv` 加 `SSH_CONNECTION` 守护的 proxy export(见部署清单第 3 步)|
| desktop 连接报 "Host denied (verification failed)",即便 ssh_configs.json 里 trustedHosts 已记 | desktop 真正用 `ssh-keygen -F <host>` 查 OpenSSH known_hosts,trustedHosts 只是 UI 上的 "我点过 trust" 标记,跟底层 verifier 无关;如果 known_hosts 没 entry 就 reject | `ssh-keyscan <host> >> ~/.ssh/known_hosts`(见部署清单第 5 步)|
| desktop 每次重连都问密码 | desktop 故意不缓存密码(安全策略),只能走 ssh key auth | 双向 `ssh-copy-id`(见部署清单第 6 步)|
| 之前 SFTP 推 server 时下到一半 DERP 链路断了,留个 partial server (917KB / 完整 5.9MB),desktop 后续 reattach 时 `test -x` 过但 `--version` exec 直接挂掉 | desktop 端 SFTP 上传**不**做完整性校验,半成品文件留在 srv/ 永久挂着 | prep 脚本预热完整 binary 后用 atomic mv,desktop 永远看不到半写状态;如果碰到老遗留,手动 `rm ~/.claude/remote/srv/<hash>/server` 重新跑 prep |
| `ssh user@host` 在终端能通,desktop UI 还报 Host denied | 同上 known_hosts 问题;终端 ssh 接受 fingerprint 后**应该**写 known_hosts,但实测有时不写(路径配置异常 / UserKnownHostsFile 不对) | 别相信"我刚才 ssh 进去过了",老老实实 `ssh-keygen -F <host>` 验证 entry 真在 |
| ssh-copy-id 还没做就关了 sshd 密码登录 → 对端 `Permission denied (publickey)`,密码登录也被拒 → 进不去任何方式 | 死锁:sshd 拒密码、authorized_keys 没你 pubkey | 远程桌面 / 物理触达对端 → 手动 `echo '<本机 pubkey>' >> ~/.ssh/authorized_keys` 救援。**预防**:严格按部署清单第 6 → 7 顺序,关密码登录前用 `ssh -o PreferredAuthentications=publickey ...` 验证 key auth 真的能通 |
| ssh config 加了 `Host *` 通配设 IdentityFile → OrbStack / 其它具体 Host 块连不上自己的 VM | OpenSSH 配置项"首次出现优先",`Host *` 在前会把后面所有 Host 块的 IdentityFile 抢先 | 把作用域改为 `Host *.tail69730a.ts.net` 等具体 pattern,不要用 `*` 通配;如果必须放 `Host *`,确保它在所有 Include / 具体 Host 块**之后** |
| 远程 ssh 进 mini 跑 `ssh-add --apple-use-keychain` 报 "Could not open a connection to your authentication agent" | sshd 子 shell 没有桌面 session 的 `SSH_AUTH_SOCK`,也访问不到桌面 keychain | 必须在 mini **本机桌面 session**(屏幕共享 / 物理键盘)跑 ssh-add 一次;之后 ssh config 里 `UseKeychain yes` 让任何 ssh client 自动从 Keychain 取 passphrase |
| `>> ~/.ssh/authorized_keys` 跑了两次,里面有完全相同的两条 pubkey | shell 重定向是 append 不去重 | `awk '!seen[$0]++' ~/.ssh/authorized_keys > tmp && mv tmp ~/.ssh/authorized_keys` 去重 |

</details>

<details>
<summary>🔒 安全加固(推荐,长期使用一定要做)</summary>

部署清单第 6/7 步已经默认包含了 passphrase + Keychain + sshd 关密码登录这两条主要加固。下面是更进一步的选项,按威胁模型对应。

**A. passphrase + Keychain 的威胁差别**(已在清单默认配置)

`--apple-use-keychain` 让 passphrase 落进 login keychain,登录后 ssh-agent 自动解锁;ssh client 通过 `UseKeychain yes` 直接从 Keychain 取 passphrase,全程无交互。desktop 的 ssh2 lib 走 `SSH_AUTH_SOCK` 拿 key。

威胁差别:磁盘镜像被偷 → 带 passphrase 的 key 仍受保护(要 brute-force passphrase);空 passphrase key 复制走就能立刻用。Keychain 本身受用户登录密码 / Touch ID 保护,攻击者还需要进入活动用户 session 才能拿到解锁 key。

**B. 限定 sshd 接受的用户**(清单已关密码登录,这里加限定用户)

清单里 `AllowUsers bobby` 已经把允许登录用户白名单化。可以再去 System Settings → Sharing → Remote Login → Allow access for → Only these users → 只勾自己账号(双保险,sshd 配置 + macOS 系统级双重控制)。

**C. Tailscale ACL 限定哪些设备能进**

即便 sshd 只接受 key auth,被偷 key 的设备仍能从 Tailscale 网络任意机器进。在 [Tailscale admin → Access Controls](https://login.tailscale.com/admin/acls) 加规则:

```jsonc
{
  "tagOwners": { "tag:mine": ["bobby@..."] },
  "acls": [
    { "action": "accept", "src": ["tag:mine"], "dst": ["tag:mine:22"] }
  ]
}
```

给 MBP / mini 打 `tag:mine` tag,手机 / 临时设备进 Tailscale 也连不上 sshd。

**D. 带外验证 host key fingerprint**

`ssh-keyscan` 一把梭在 MITM 攻击窗口内等于自己授信中间人。正确做法:从对端物理/带外渠道拿 fingerprint 比对:

```bash
# 在对端机器跑
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

# 在本机比对
ssh-keyscan <对端 host> 2>/dev/null | ssh-keygen -lf -
# 两边 SHA256 必须完全一致才能信任
```

Tailscale WG 加密 + 设备身份验证 → 中间人攻击窗口很小;公网 SSH 时这步是必需的。

**E. `.zshenv` 代理 env 限定来源 IP**

把代理注入限制为只对 Tailscale 网段(`100.x.x.x`)来源的 SSH session 生效:

```bash
if [ -n "$SSH_CONNECTION" ]; then
  client_ip="${SSH_CONNECTION%% *}"
  case "$client_ip" in
    100.*) export HTTPS_PROXY=http://127.0.0.1:6152
           export HTTP_PROXY=http://127.0.0.1:6152
           export NO_PROXY=localhost,127.0.0.1 ;;
  esac
fi
```

非 Tailscale 来源的 SSH 拿不到 proxy env,外发只走机器真实出口,自然阻断代理滥用路径。

**F. 不要把 ssh key / 代理配置 commit 进仓库**

`~/.ssh/`、`~/.zshenv`、`/etc/ssh/sshd_config.d/local.conf` 这些**绝对**不要 commit 到 mac-launchd 或任何 git 仓库。换机器恢复时手动配,或用 dotfiles 私有仓库(带加密)单独管。本仓库只放无 secret 的 launchd plist / 脚本。

---

**威胁模型小结**:部署清单已默认含 passphrase + Keychain + sshd 关密码登录(A、B 基础)。重视隐私加 C(Tailscale ACL),公网 SSH 加 D(带外验证 host key),对 SSH 横向移动敏感加 E(proxy env 限定 source IP)。F 是任何情况都必须遵守的红线。

</details>

---

## crash-notify

监听 macOS 崩溃报告 + 指定私有 dump 目录,有新崩溃就弹**本地通知横幅**(`terminal-notifier`)。LaunchAgent,由 `WatchPaths` 触发——被监听目录一变才跑一次,常驻零开销;纯用户级,免 sudo,脚本直接从仓库路径跑。

**覆盖两类崩溃:**

| 类型 | 来源 | 例子 |
|---|---|---|
| 走系统崩溃报告的 app | `~/Library/Logs/DiagnosticReports/*.ips`、`/Library/Logs/DiagnosticReports/*.ips` | Codex、绝大多数原生 app |
| 自带崩溃处理器(Breakpad/Crashpad)的 app | 各自私有 dump 目录(`CN_DUMP_DIRS` 配置) | ToDesk(`/Library/Application Support/ToDesk/dumps/*.dmp`) |

> ⚠️ 自带崩溃处理器的 app **不进** DiagnosticReports(自己拦信号写私有 dump),所以必须显式把其 dump 目录加进来才抓得到。

**防崩溃循环刷屏**(吃过 ToDesk 每 10s 崩一次、能弹几百条的亏):

- 同一进程两条横幅最短间隔 `CN_COOLDOWN`(默认 300s),冷却内仍记日志、不弹横幅;
- 单次扫描内同进程崩溃数 ≥ `CN_LOOP_THRESHOLD`(默认 5)判为**崩溃循环**,合并成一条 `💥 X 崩溃循环` 横幅;
- `WatchPaths` 触发由 launchd 节流到最快每 10s 一次(`ThrottleInterval`);
- `fcntl` 文件锁,并发触发只让一个实例处理,杜绝重复通知。

**安装即打基线**:`install.sh` 会先 `crash-notify.sh seed` 把现有崩溃全标记为已读,只通知此后的新崩溃,不补报历史。

**新增要监听的私有 dump 目录**:在 `crash-notify.sh` 的 `CN_DUMP_DIRS` 加一行 `目录|显示名|扩展名`,**并**把同一目录加到 `com.jizhi.crash-notify.plist` 的 `WatchPaths`(否则不会被触发)。

```
安装:  cd crash-notify && ./install.sh
自测:  /opt/homebrew/bin/terminal-notifier -title '💥 测试' -message ok
日志:  tail -f ~/Library/Logs/crash-notify.log
卸载:  ./uninstall.sh
```

**已知局限**:Codex 这类崩在系统宿主进程里的(`com.apple.dock.external.extra`),横幅显示的是宿主进程名而非真正肇事 app —— 详情看日志 / `.ips` 里的 faulting image。

---

## claude-wake

远控**逃生舱**:本机常驻一个**只听 127.0.0.1 的小触发器**,远端戳一下就**现起一个全新的** `claude --remote-control` 会话,把 `claude.ai/code` 接管链接回给你 —— 点开就在 App / 网页端控制。

**为什么是「唤醒」而不是「常驻一个会话」**:RC 是一条**活的云连接**,网络抖动会把它打断进 archived 态 —— 常驻会话于是变僵尸、抓不回来,人又被锁在门外。改成**每次现起一个全新会话**:全新连接,没有陈旧断链问题。而触发器本身**不持有云连接**(只是被 tailscale/surge 转进来的一次性本地调用),所以抖动锁不住它 —— 哪怕一个 RC 会话都没有,触发器永远在。

**链路**:`tailscale serve` 把 `https://<主机>.<tailnet>.ts.net/` 用 HTTPS 暴露到你自己的 tailnet(**仅本人设备可达**),再叠一层 token。**Surge ponte 作后备**(tailscale 挂了时):把 ponte 指到 `127.0.0.1:8765`,带同样 token 访问。RC 本身走 Anthropic 云,这俩只是「到机器」的链路冗余。

**机制**:`claude --remote-control` 要 PTY,launchd/代理裸 spawn 没 TTY → 塞进 **tmux**。每次 wake 先 `reap`(收掉上一个可能已断的会话)再 spawn 全新的,然后盯 pane 抓出 `claude.ai/code/session_…` 链接返回。代理同 [claude-ssh-prep](#claude-ssh-prep):LaunchAgent 子进程不继承 shell 的 proxy env,从 `scutil` 读系统级 HTTPS 代理补上(每次 spawn 重读,跟随换网),否则 RC 注册报 "Session creation failed"。

**凭据(给 claude 自己用的,不是门锁 token)**:wake 会话默认**继承本机交互登录态**(`~/.claude/.credentials.json` 的 OAuth),但那个 access token 几小时就过期,靠 `refreshToken` 静默续 —— **refreshToken 一旦失效**(别处重登 / 改密 / 服务端轮转)**下一次 wake 就要交互 `/login`,而 RC 会话没法交互 → 逃生舱在你不在时正好挂掉**。所以可选注入一个**长效 token**(`claude setup-token` 签,约 1 年免续):写进 `~/.config/claude-wake/oauth-token`(chmod 600),spawn 时透传成 `CLAUDE_CODE_OAUTH_TOKEN`,claude 改用它、和本机交互登录态彻底解耦。代价:这是张长效持票凭据,泄了等于交出账号约一年 —— 别进 plist 明文 / git,到期记得重签。没配这个文件就静默退回继承登录态。

**鉴权 / 安全**:
- **唤醒只走 POST** —— `GET /` 只回一个落地页(带「唤醒」按钮),**没有副作用**。所以在浏览器里直接打开 URL(书签被重开 / 预取 / 历史缩略图刷新 / 链接预览)都**不会**误起 RC 会话;必须显式点按钮或用 Shortcut 发 POST 才 spawn。
- listener 只绑 `127.0.0.1`(不上局域网);除 `/health` 外都要 token(`Authorization: Bearer` / `?token=` / 表单字段 / `cwtok` Cookie,常数时间比对);token 48 hex(192-bit)存 `~/.config/claude-wake/token`(chmod 600)。首个带 token 的请求种 `HttpOnly + SameSite=Strict` Cookie,之后 `/browse` 导航链接不必带 token(不污染浏览历史、挡 CSRF)。
- **`/browse` 目录浏览限死在 `WAKE_BROWSE_ROOT`(默认 `$HOME`)内**:请求路径 `realpath` 后必须落在根内,`../` 与符号链接逃逸一并挡掉(逃逸的软链在列表里直接藏掉),默认还藏点目录(`?all=1` 才显示)。
- `dir` 参数:绝对路径(`/browse` 表单给的)`realpath` 后必须在根内,裸名字必须是 `/dirs` 已知仓库,否则拒绝(杜绝 `dir=/etc`);只进 `tmux -c`(不拼进命令串,无注入)。
- 会话**不带** `--dangerously-skip-permissions` —— 就算别人拿 token 戳出会话,也得用**你账号登录的 App** 才能驱动,且每步权限你还得点。

**可调**(plist `EnvironmentVariables` / `WAKE_PORT` 等 export 覆盖):

| 变量 | 默认 | 说明 |
|---|---|---|
| `WAKE_PORT` | `8765` | listener 端口(tailscale serve / ponte 指这里) |
| `WAKE_DIR` | `/tmp/claude-wake-cwd` | 新会话默认起始目录(空目录秒起;`?dir=` 或 `/browse` 选目录可单次覆盖) |
| `WAKE_BROWSE_ROOT` | `$HOME` | `/browse` 文件浏览/选目录的根,限死在内防越界 |
| `WAKE_RC_NAME` | `wake-<LocalHostName>` | App 里显示的会话名 |
| `WAKE_SESSION` | `wake` | tmux 会话名 |
| `WAKE_CAPTURE_TIMEOUT` | `45` | 等 RC 链接出现的秒数 |
| `WAKE_OAUTH_FILE` | `~/.config/claude-wake/oauth-token` | 长效 `CLAUDE_CODE_OAUTH_TOKEN` 来源(`claude setup-token` 签);缺省退回继承本机登录态 |

```
安装:    cd claude-wake && ./install.sh   # 生成 token + 配 tailscale serve,打印唤醒 URL
本地测:  curl -s -X POST -d "token=$(cat ~/.config/claude-wake/token)" http://127.0.0.1:8765/wake
手机唤醒: 浏览器开 https://<主机>.<tailnet>.ts.net/?token=<token> → 点「唤醒」按钮 → 点返回链接接管
         （或 Shortcut: POST /wake + header Authorization: Bearer <token>,token 不进 URL）
路由:    GET / 落地页(无副作用,带「📂 浏览目录」入口) · GET /browse[?path=][&all=1] 文件浏览选目录(限死 $HOME 内,纯链接前进/后退) · POST /wake[?dir=](带 Accept: application/json 回 {"url"}) 起会话 · GET /dirs 列 ~/Developer 下 git 仓库(给快捷指令选文件夹) · GET /status 看当前 · GET /health 探活(免 token)
长效凭据: claude setup-token  → umask 077; printf '%s' '<token>' > ~/.config/claude-wake/oauth-token  (无人值守必备,免 refreshToken 失效后人肉重登)
到期提醒: install.sh 顺带装第二个 agent(com.jizhi.claude-wake-tokencheck),每天查长效 token 的 mtime 年龄,过 330 天起弹横幅催你重签(token 不透明、读不出过期时间,按签发时刻近似)。手动验证: bash claude-wake-token-check.sh now
换 token: rm ~/.config/claude-wake/token && ./install.sh
卸载:    ./uninstall.sh   # 撤 tailscale serve + 收掉 wake 会话(token 保留)
```

**已知局限**:① token 放 query 会进浏览器历史/可能进日志 —— 在意就用 Shortcut 走 `Authorization` header。② `uninstall.sh` 撤 serve 用 `tailscale serve --https=443 off`,不行则 `reset`(会清掉**所有** serve 映射);本仓库装它时 serve 本是空的,若你后来加过别的映射,卸载后核对一下 `tailscale serve status`。③ Surge ponte 那一路是 app 配置,脚本不替你配。
