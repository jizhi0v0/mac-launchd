#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.local.offline-translator"
OLD_LABEL="com.local.hy-mt-llama-server"   # 旧版 llama.cpp system daemon
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/${LABEL}.plist"
SRC="$DIR/${LABEL}.plist"

APP="$HOME/.local/share/offline-translator"
VENV="$APP/venv"
MODEL_DIR_NAME="Hy-MT2-1.8B-mlx-4bit"
MODEL="$APP/$MODEL_DIR_NAME"
LINK="$APP/Hy-MT2-1.8B"                     # 中性 model id：软链 -> 当前量化目录，与量化解耦
MLX_REPO="jizhiovo/Hy-MT2-1.8B-mlx-4bit"   # 预量化 4-bit MLX（~977MB）
SRC_REPO="tencent/Hy-MT2-1.8B"             # 原始权重，仅在下载失败时本地转换用

# --- 0. 清掉旧版 llama.cpp system daemon（如果存在，需要 sudo）---
if [ -f "/Library/LaunchDaemons/${OLD_LABEL}.plist" ]; then
    echo "removing old llama.cpp system daemon ($OLD_LABEL) — needs sudo..."
    sudo launchctl bootout system "/Library/LaunchDaemons/${OLD_LABEL}.plist" 2>/dev/null || true
    sudo rm -f "/Library/LaunchDaemons/${OLD_LABEL}.plist"
fi

# --- 1. venv + mlx-lm（用 uv）---
if ! command -v uv >/dev/null 2>&1; then
    echo "error: uv not found. install: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi
mkdir -p "$APP"
if [ ! -x "$VENV/bin/python" ]; then
    echo "creating venv at $VENV ..."
    uv venv --python 3.12 "$VENV"
fi
echo "installing/updating mlx-lm ..."
uv pip install -q --python "$VENV/bin/python" mlx-lm

# --- 2. 模型：curl 直连 resolve 下 4-bit MLX（绕开 hf 的 Xet 通道——实测会卡 0B）。
#         下不全则本地从原始权重转换。 ---
if [ ! -f "$MODEL/model.safetensors" ]; then
    echo "downloading 4-bit MLX model ($MLX_REPO, ~977MB) via curl ..."
    mkdir -p "$MODEL"
    BASE="https://huggingface.co/$MLX_REPO/resolve/main"
    FILES=$("$VENV/bin/python" - "$MLX_REPO" <<'PY'
import sys
from huggingface_hub import HfApi
print("\n".join(f.rfilename for f in HfApi().model_info(sys.argv[1]).siblings))
PY
)
    ok=1
    for f in $FILES; do
        case "$f" in */*) continue;; esac          # 只要顶层模型文件，跳过 imgs/ 等
        echo "  - $f"
        curl -fSL -C - --retry 8 --retry-delay 3 "$BASE/$f" -o "$MODEL/$f" || ok=0
    done
    # 校验权重头部，半截文件视为失败
    "$VENV/bin/python" -c "import struct,json; f=open('$MODEL/model.safetensors','rb'); n=struct.unpack('<Q',f.read(8))[0]; json.loads(f.read(n))" 2>/dev/null || ok=0
    if [ $ok -ne 1 ]; then
        echo "curl download incomplete -> falling back to local conversion from $SRC_REPO (~3.6GB + 量化) ..."
        rm -rf "$MODEL"
        "$VENV/bin/python" -m mlx_lm convert --hf-path "$SRC_REPO" -q --q-bits 4 --mlx-path "$MODEL"
    fi
fi

# 中性 id 软链（plist 里 --model 用的就是它；以后换量化只改这条软链指向，客户端不用动）
ln -sfn "$MODEL_DIR_NAME" "$LINK"

# --- 3. 释放 8110（清掉任何残留监听者，含手动起的 mlx/llama-server）---
for pid in $(lsof -nP -iTCP:8110 -sTCP:LISTEN -t 2>/dev/null || true); do
    echo "freeing port 8110 (killing stray pid $pid) ..."
    kill "$pid" 2>/dev/null || true
done
sleep 1

# --- 4. 安装 + 加载 LaunchAgent（gui/$UID，可访问 Metal GPU）---
mkdir -p "$AGENT_DIR"
TMP=$(mktemp)
sed "s|__HOME__|$HOME|g" "$SRC" > "$TMP"
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
install -m 644 "$TMP" "$PLIST"
rm -f "$TMP"
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true

echo "installed as user LaunchAgent (MLX / Metal, starts at login)"
echo "endpoint: http://127.0.0.1:8110/v1   model name: Hy-MT2-1.8B"
echo "logs: /tmp/offline-translator.{out,err}.log"
