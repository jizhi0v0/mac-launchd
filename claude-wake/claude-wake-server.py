#!/usr/bin/env python3
"""claude-wake 的 HTTP 前端。

只听 127.0.0.1:$WAKE_PORT，对外靠 `tailscale serve`(https, 仅本人 tailnet 可达)
+ Surge ponte(后备) 转进来。除 /health 外都要 token：
  - header  `Authorization: Bearer <token>`
  - query   `?token=<token>`        （GET 落地页用）
  - 表单字段 token=<token>           （落地页按钮 POST 用）

**安全要点：唤醒是有副作用的，只走 POST。** GET 不 spawn，只回落地页 —— 这样在浏览器
里直接打开 URL（含书签被重开 / 预取 / 历史缩略图刷新）都**不会**误起会话，必须显式点
「唤醒」按钮或用 Shortcut 发 POST。

路由：
  GET  /  或 /wake [?token=]  → 落地页（显示当前会话 + 一个「唤醒」按钮）。无副作用。
  POST /  或 /wake            → reap+spawn 一个全新 claude RC 会话，返回接管链接。
  GET  /status                → 当前 wake 会话的链接（若在）。无副作用。
  GET  /health                → ok（不鉴权，给 tailscale/监控探活）。

实际起会话的脏活全在 claude-wake.sh（WAKE_SH 指过去）。
"""
import html
import hmac
import os
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("WAKE_PORT", "8765"))
TOKEN_FILE = os.environ.get(
    "WAKE_TOKEN_FILE", os.path.expanduser("~/.config/claude-wake/token")
)
WAKE_SH = os.environ.get("WAKE_SH", "")


def load_token():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


TOKEN = load_token()


def token_ok(tok):
    return bool(TOKEN) and bool(tok) and hmac.compare_digest(tok, TOKEN)


def run_wake(*args, timeout=60):
    return subprocess.run(
        [WAKE_SH, *args], capture_output=True, text=True, timeout=timeout
    )


PAGE_HEAD = (
    '<!doctype html><meta charset=utf-8>'
    '<meta name=viewport content="width=device-width,initial-scale=1">'
    '<body style="font-family:-apple-system,system-ui;max-width:34rem;margin:0 auto;'
    'padding:2rem;font-size:1.2rem;line-height:1.6">'
)


def landing_page(token, status_text):
    safe_tok = html.escape(token)
    status = html.escape(status_text.strip()) or "(无)"
    link = ""
    if status_text.startswith("https://"):
        u = html.escape(status_text.strip())
        link = f'<p>当前会话：<a href="{u}">{u}</a></p>'
    else:
        link = f"<p style=color:#888>当前：{status}</p>"
    return (
        PAGE_HEAD
        + "<h2>🛟 claude-wake</h2>"
        + link
        + '<form method="POST" action="/wake" style="margin-top:1.5rem">'
        + f'<input type="hidden" name="token" value="{safe_tok}">'
        + '<button style="font-size:1.3rem;padding:.9rem 2rem;border-radius:.6rem;'
        'border:0;background:#d97757;color:#fff">唤醒一个新会话</button>'
        + "</form>"
        + '<p style="color:#aaa;font-size:.9rem;margin-top:2rem">'
        "点按钮才会起新会话；直接打开本页不会。</p>"
        + "</body>"
    )


def result_page(url):
    u = html.escape(url)
    return (
        PAGE_HEAD
        + "<p>✅ 会话已就绪</p>"
        + f'<p style="font-size:1.35rem"><a href="{u}">{u}</a></p>'
        + '<p style=color:#888>点链接在 Claude App / 网页端接管</p>'
        + '<p style="margin-top:1.5rem"><a href="/wake?token=__T__">↻ 再唤醒一个</a></p>'
        + "</body>"
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-wake"

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    # 静音默认访问日志：token 可能在 query 里，别落盘
    def log_message(self, *a):
        pass

    def _header_token(self):
        auth = self.headers.get("Authorization", "")
        return auth[7:].strip() if auth.startswith("Bearer ") else ""

    # ---- GET：只读，绝不 spawn ----
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        q = urllib.parse.parse_qs(parsed.query)

        if path in ("/health", "/healthz"):
            return self._send(200, "ok\n", "text/plain; charset=utf-8")

        tok = self._header_token() or q.get("token", [""])[0]
        if not token_ok(tok):
            return self._send(401, "unauthorized\n", "text/plain; charset=utf-8")

        if path in ("/", "/wake"):
            st = run_wake("status", timeout=10).stdout
            return self._send(200, landing_page(tok, st))
        if path == "/status":
            return self._send(
                200, run_wake("status", timeout=10).stdout or "n/a\n",
                "text/plain; charset=utf-8",
            )
        return self._send(404, "not found\n", "text/plain; charset=utf-8")

    # ---- POST：有副作用，唯一会 spawn 的入口 ----
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        form = urllib.parse.parse_qs(body)
        q = urllib.parse.parse_qs(parsed.query)

        tok = self._header_token() or form.get("token", [""])[0] or q.get("token", [""])[0]
        if not token_ok(tok):
            return self._send(401, "unauthorized\n", "text/plain; charset=utf-8")

        if path in ("/", "/wake"):
            d = form.get("dir", [""])[0] or q.get("dir", [""])[0]
            args = ["wake"] + ([d] if d else [])
            try:
                out = run_wake(*args)
            except subprocess.TimeoutExpired:
                return self._send(504, "wake timed out\n", "text/plain; charset=utf-8")
            if out.returncode == 0:
                page = result_page(out.stdout.strip()).replace("__T__", html.escape(tok))
                return self._send(200, page)
            return self._send(
                500, "wake failed:\n" + out.stderr, "text/plain; charset=utf-8"
            )
        return self._send(404, "not found\n", "text/plain; charset=utf-8")


def main():
    if not TOKEN:
        sys.exit(f"[claude-wake] no token at {TOKEN_FILE} — 先跑 install.sh")
    if not WAKE_SH or not os.path.exists(WAKE_SH):
        sys.exit(f"[claude-wake] WAKE_SH 未设置或不存在: {WAKE_SH!r}")
    print(f"[claude-wake] listening on {HOST}:{PORT} (wake={WAKE_SH})", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
