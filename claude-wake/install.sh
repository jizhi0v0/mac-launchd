#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jizhi.claude-wake"
SERVER="$DIR/claude-wake-server.py"
WAKESH="$DIR/claude-wake.sh"
PLIST_SRC="$DIR/${LABEL}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

PORT="${WAKE_PORT:-8765}"
TOKEN_DIR="$HOME/.config/claude-wake"
TOKEN_FILE="$TOKEN_DIR/token"

# 依赖（早失败比 agent 跑起来才报错好）
command -v tmux >/dev/null || { echo "需要 tmux: brew install tmux"; exit 1; }
command -v /usr/bin/python3 >/dev/null || { echo "需要 /usr/bin/python3（xcode-select --install）"; exit 1; }
PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH" command -v claude >/dev/null \
  || { echo "PATH 里找不到 claude（应在 ~/.local/bin）"; exit 1; }

chmod +x "$WAKESH" "$SERVER"

# 生成 token（已存在就复用，免得换机/重装后书签失效）
mkdir -p "$TOKEN_DIR"; chmod 700 "$TOKEN_DIR"
if [ ! -s "$TOKEN_FILE" ]; then
  openssl rand -hex 24 > "$TOKEN_FILE"
  echo "生成新 token → $TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"
TOKEN="$(cat "$TOKEN_FILE")"

# 占位符 → 绝对路径，让 plist 跟仓库脚本绑定（git pull 改脚本即生效）
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__SERVER__|$SERVER|g" \
    -e "s|__WAKESH__|$WAKESH|g" \
    -e "s|__PORT__|$PORT|g" \
    -e "s|__TOKEN__|$TOKEN_FILE|g" \
    "$PLIST_SRC" > "$PLIST_DST"

# 幂等：先 bootout 再 bootstrap
launchctl bootout "gui/$UID_NUM" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

# 经 tailscale serve 用 https 暴露到自己的 tailnet（仅本人设备可达，叠加 token）
TS_URL=""
if command -v tailscale >/dev/null; then
  if tailscale serve --bg "$PORT" >/dev/null 2>&1; then
    DNS="$(tailscale status --json 2>/dev/null \
      | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
    [ -n "$DNS" ] && TS_URL="https://$DNS"
    echo "tailscale serve: https://$DNS/ → 127.0.0.1:$PORT"
  else
    echo "⚠️ tailscale serve 配置失败（手动：tailscale serve --bg $PORT）"
  fi
else
  echo "⚠️ 没装 tailscale CLI，跳过 serve（自行暴露 127.0.0.1:$PORT）"
fi

cat <<EOF

installed (用户级 LaunchAgent, 无需 sudo).
日志:   /tmp/claude-wake.{out,err}.log
本地测: curl -s -X POST -d "token=$TOKEN" 'http://127.0.0.1:$PORT/wake'

== 远程唤醒（手机）== 唤醒只走 POST；GET 只回落地页，直接打开 URL 不会误起会话
  浏览器/书签:  ${TS_URL:-https://<你的-tailnet-host>}/?token=$TOKEN
               （打开 → 点「唤醒一个新会话」按钮 → 点返回里的 claude.ai/code 链接接管）
  一键 Shortcut: POST ${TS_URL:-https://<host>}/wake  + header  Authorization: Bearer $TOKEN
               （token 不进 URL，最干净；返回 HTML 里就是接管链接）

== Surge ponte 后备 ==
  在 Surge 配置里把 ponte 指到 127.0.0.1:$PORT，然后用 ponte 域名带同样的 token 访问。

⚠️ RC 需要本机 claude **交互登录态**（keychain，full-scope）。别用 claude setup-token——
   那是 inference-only、开不了 RC（"Session creation failed"）。无人值守时若 refreshToken 失效，
   需在本机重登一次（RC 没有长效 full-scope token 这个选项）。

token 存于 $TOKEN_FILE（chmod 600）。泄露了就 rm 它再重跑 install.sh 换新。
状态:   launchctl print gui/$UID_NUM/$LABEL
EOF
