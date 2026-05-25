#!/bin/bash
# 预热 Claude desktop 的 SSH remote agent + claude CLI zst，让 desktop 通过 SSH
# 连过来时跳过 SFTP/HTTPS 自下载（DERP/Surge ponte 链路下大文件常断）。
#
# 触发：app.asar mtime 变化（desktop 升级）/ launchd RunAtLoad（安装、登录、重启）
# 操作（幂等）：
#   1. 读 app.asar 抠两份 manifest：claude-ssh + claude-code
#   2. 拉 claude-ssh.zst → 解压 → ~/.claude/remote/srv/<hash>/server
#   3. 拉 claude.zst → ~/.claude/remote/ccd-cli/<version>.zst（保留压缩态，
#      server --install 自己解）
# 目标文件存在且 sha256 对 → 直接 skip，零成本。

set -euo pipefail

ASAR="/Applications/Claude.app/Contents/Resources/app.asar"
REMOTE_DIR="$HOME/.claude/remote"
SRV_DIR="$REMOTE_DIR/srv"
CCD_DIR="$REMOTE_DIR/ccd-cli"

log() { printf '%s [claude-ssh-prep] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# desktop 还没装就静默退出，不算错（首次 fresh mac 触发 RunAtLoad 时正常情况）
[ -f "$ASAR" ] || { log "Claude.app not installed at $ASAR; skipping"; exit 0; }

command -v zstd >/dev/null || die "需要 zstd: brew install zstd"
command -v python3 >/dev/null || die "需要 python3（macOS 自带，可能要 xcode-select --install）"

# 平台 detect（agent + CLI 在 manifest 里用同套 key）
case "$(uname -m)" in
  arm64)  PLATFORM=darwin-arm64 ;;
  x86_64) PLATFORM=darwin-x64 ;;
  *)      die "unsupported arch: $(uname -m)" ;;
esac

# 走系统 HTTPS 代理（Surge ponte 等）—— LaunchAgent 子进程不继承用户 shell 的
# proxy env，但能通过 scutil --proxy 读系统级配置。mini 直连 downloads.claude.ai
# 实测不通，必须走代理。
PROXY_HOST=$(scutil --proxy 2>/dev/null | awk '/HTTPSProxy *: / { print $3; exit }')
PROXY_PORT=$(scutil --proxy 2>/dev/null | awk '/HTTPSPort *: / { print $3; exit }')
if [ -n "${PROXY_HOST:-}" ] && [ -n "${PROXY_PORT:-}" ]; then
  export HTTPS_PROXY="http://$PROXY_HOST:$PROXY_PORT"
  export https_proxy="$HTTPS_PROXY"
  log "using system HTTPS proxy $HTTPS_PROXY"
fi

# 从 ASAR 抠两份 manifest（ssh agent + cli），输出五元组
read -r SSH_VERSION SSH_CHECKSUM CLI_VERSION CLI_CHECKSUM CLI_BINARY < <(
  python3 - "$ASAR" "$PLATFORM" <<'PY'
import json, re, sys
asar_path, platform = sys.argv[1], sys.argv[2]
with open(asar_path, 'rb') as f:
    data = f.read().decode('utf-8', errors='ignore')

def find_manifest(base_url_substr):
    # JSON.parse('{...}') 形式硬编码在 ASAR，定位到 baseUrl 子串，回溯找
    # JSON.parse(' 边界，前向找 ')。两个 manifest 用同一模板。
    for m in re.finditer(re.escape(base_url_substr), data):
        start = data.rfind("JSON.parse('", max(0, m.start() - 6000), m.start())
        if start < 0:
            continue
        start += len("JSON.parse('")
        end = data.find("')", m.end())
        if end < 0:
            continue
        raw = data[start:end]
        # JS 字符串字面量里的转义还原（保守只处理常见两种）
        raw = raw.replace("\\'", "'").replace('\\\\', '\\')
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            continue
    return None

ssh = find_manifest('claude-ssh-releases')
cli = find_manifest('claude-code-releases')
if not ssh:
    sys.exit('ssh agent manifest not found in app.asar')
if not cli:
    sys.exit('claude CLI manifest not found in app.asar')

ssh_plat = ssh['manifest']['platforms'].get(platform)
cli_plat = cli['manifest']['platforms'].get(platform)
if not ssh_plat:
    sys.exit(f'ssh agent has no platform {platform}')
if not cli_plat:
    sys.exit(f'cli has no platform {platform}')

# ssh agent URL 末尾固定 claude-ssh.zst（manifest 里没 binary 字段）；
# cli URL 末尾用 binary 字段（macOS=claude.zst，windows=claude.exe.zst）
print(ssh['version'], ssh_plat['checksum'],
      cli['version'], cli_plat['checksum'],
      cli_plat.get('binary', 'claude.zst'))
PY
)

log "ssh agent: $SSH_VERSION; cli: $CLI_VERSION ($CLI_BINARY) for $PLATFORM"

# ---------- 预热 SSH agent ----------
SSH_DIR="$SRV_DIR/$SSH_VERSION"
SSH_TARGET="$SSH_DIR/server"
SSH_URL="https://downloads.claude.ai/claude-ssh-releases/$SSH_VERSION/$PLATFORM/claude-ssh.zst"

mkdir -p "$SSH_DIR"
chmod 700 "$HOME/.claude" "$REMOTE_DIR" "$SRV_DIR" "$SSH_DIR" 2>/dev/null || true

# desktop 判定 "已部署" 的标准：test -x server && server --version 输出含期望 hash
# (Nvr in app.asar)。我们对齐这条契约。
if [ -x "$SSH_TARGET" ] \
   && "$SSH_TARGET" --version 2>/dev/null | grep -q "$SSH_VERSION"; then
  log "ssh agent up-to-date: $SSH_VERSION"
else
  log "fetching ssh agent $SSH_VERSION ($SSH_URL)"
  TMP_ZST=$(mktemp -t claude-ssh.zst.XXXXXX)
  trap 'rm -f "$TMP_ZST"' EXIT
  curl -fL --max-time 120 --retry 2 --retry-delay 3 \
       "$SSH_URL" -o "$TMP_ZST"
  ACTUAL=$(shasum -a 256 "$TMP_ZST" | awk '{print $1}')
  [ "$ACTUAL" = "$SSH_CHECKSUM" ] \
    || die "ssh agent checksum mismatch (want=$SSH_CHECKSUM got=$ACTUAL)"
  # 解压到 tmp 再 mv，避免半写状态被 desktop 看到（之前 mini 上 partial server 害死过一次）
  TMP_BIN=$(mktemp -t claude-ssh.bin.XXXXXX)
  trap 'rm -f "$TMP_ZST" "$TMP_BIN"' EXIT
  zstd -d -f "$TMP_ZST" -o "$TMP_BIN"
  chmod 0755 "$TMP_BIN"
  mv "$TMP_BIN" "$SSH_TARGET"
  rm -f "$TMP_ZST"
  trap - EXIT
  log "installed ssh agent at $SSH_TARGET"
fi

# ---------- 预热 CLI zst ----------
mkdir -p "$CCD_DIR"
chmod 700 "$CCD_DIR"
CLI_TARGET="$CCD_DIR/$CLI_VERSION.zst"
CLI_URL="https://downloads.claude.ai/claude-code-releases/$CLI_VERSION/$PLATFORM/$CLI_BINARY"

if [ -f "$CLI_TARGET" ] \
   && [ "$(shasum -a 256 "$CLI_TARGET" | awk '{print $1}')" = "$CLI_CHECKSUM" ]; then
  log "cli zst up-to-date: $CLI_VERSION"
else
  log "fetching cli zst $CLI_VERSION ($CLI_URL)"
  TMP_CLI=$(mktemp -t claude-cli.zst.XXXXXX)
  trap 'rm -f "$TMP_CLI"' EXIT
  curl -fL --max-time 600 --retry 2 --retry-delay 5 \
       "$CLI_URL" -o "$TMP_CLI"
  ACTUAL=$(shasum -a 256 "$TMP_CLI" | awk '{print $1}')
  [ "$ACTUAL" = "$CLI_CHECKSUM" ] \
    || die "cli zst checksum mismatch (want=$CLI_CHECKSUM got=$ACTUAL)"
  mv "$TMP_CLI" "$CLI_TARGET"
  trap - EXIT
  log "installed cli zst at $CLI_TARGET"
fi

log "done"
