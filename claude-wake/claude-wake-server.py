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
  POST /  或 /wake [dir=…]    → reap+spawn 一个全新 claude RC 会话，返回接管链接。
                                带 Accept: application/json（或 ?format=json）则回 {"url": …}。
  GET  /dirs                  → WAKE_DIR_ROOTS（默认 ~/Developer）下 git 仓库的 name→路径 JSON，
                                给 Shortcut 当文件夹选择列表。
  GET  /browse [?path=]       → 目录浏览页（从 WAKE_BROWSE_ROOT，默认 $HOME 起，纯链接前进/后退），
                                每页一个「在此目录唤醒」POST 按钮。只读、限死在根内（防 ../ 与符号链接逃逸）。
  GET  /status                → 当前 wake 会话的链接（若在）。无副作用。
  GET  /health                → ok（不鉴权，给 tailscale/监控探活）。

实际起会话的脏活全在 claude-wake.sh（WAKE_SH 指过去）。
"""
import html
import hmac
import json
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
# /dirs 列哪些目录：扫这些根下的 git 仓库（含 .git 的目录）。冒号分隔多个根。
WAKE_DIR_ROOTS = os.environ.get("WAKE_DIR_ROOTS", os.path.expanduser("~/Developer"))
# /browse 文件浏览的根；所有浏览/唤醒目录都被 realpath 后限死在这个根内（防 ../ 与符号链接逃逸）。
BROWSE_ROOT = os.path.realpath(
    os.environ.get("WAKE_BROWSE_ROOT", os.path.expanduser("~"))
)


def in_root(abs_path):
    """abs_path（须已 realpath）是否在 BROWSE_ROOT 内（含等于根本身）。"""
    return abs_path == BROWSE_ROOT or abs_path.startswith(BROWSE_ROOT + os.sep)


def resolve_in_root(rel):
    """把请求的相对路径解析成根内的绝对目录；越界 / 非目录 / 符号链接逃逸 → None。"""
    target = os.path.realpath(os.path.join(BROWSE_ROOT, (rel or "").lstrip("/")))
    if not in_root(target) or not os.path.isdir(target):
        return None
    return target


def list_subdirs(abs_path, show_hidden=False):
    """abs_path 下的子目录名（升序）；默认藏点目录（Finder 同款），跳过无权限项与
    会逃逸根的符号链接。"""
    out = []
    try:
        with os.scandir(abs_path) as it:
            for e in it:
                if not show_hidden and e.name.startswith("."):
                    continue
                try:
                    if not e.is_dir():
                        continue
                except OSError:
                    continue
                if not in_root(os.path.realpath(e.path)):
                    continue  # 符号链接指到根外，藏掉
                out.append(e.name)
    except OSError:
        pass
    return sorted(out, key=str.lower)


def list_project_dirs(max_depth=3):
    """扫 WAKE_DIR_ROOTS 下的 git 仓库，返回 name→绝对路径（给 Shortcut 当文件夹列表）。
    遇到仓库就不再往里递归；同名目录用上一级名字消歧。"""
    out = {}
    for root in WAKE_DIR_ROOTS.split(":"):
        root = os.path.expanduser(root.strip()).rstrip("/")
        if not os.path.isdir(root):
            continue
        base = root.count(os.sep)
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath.count(os.sep) - base >= max_depth:
                dirnames[:] = []
                continue
            if ".git" in dirnames or ".git" in filenames:
                name = os.path.basename(dirpath)
                if name in out and out[name] != dirpath:
                    name = os.path.basename(os.path.dirname(dirpath)) + "/" + name
                out[name] = dirpath
                dirnames[:] = []  # 不再往仓库里递归
    return dict(sorted(out.items()))


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
        + '<p style="margin-top:1.2rem"><a href="/browse">📂 浏览目录，选一个起会话…</a></p>'
        + '<p style="color:#aaa;font-size:.9rem;margin-top:2rem">'
        "点按钮才会起新会话；直接打开本页不会。</p>"
        + "</body>"
    )


def browse_page(token, abs_path, show_hidden=False):
    """目录浏览页：纯链接导航（点子目录=前进、浏览器后退键=后退、⬆️=上级），
    外加一个「在此目录唤醒」POST 按钮。token 走 Cookie，链接里不带。"""
    safe_tok = html.escape(token)
    rel = "" if abs_path == BROWSE_ROOT else os.path.relpath(abs_path, BROWSE_ROOT)
    crumb = html.escape("~/" + rel if rel else "~")
    hp = "&all=1" if show_hidden else ""  # 导航时保持「显示隐藏」状态
    rows = []
    if abs_path != BROWSE_ROOT:
        parent = urllib.parse.quote(os.path.dirname(rel))
        rows.append(f'<a class=row href="/browse?path={parent}{hp}">⬆️ 上级</a>')
    for name in list_subdirs(abs_path, show_hidden):
        child = urllib.parse.quote((rel + "/" + name) if rel else name)
        rows.append(f'<a class=row href="/browse?path={child}{hp}">📁 {html.escape(name)}</a>')
    body = "".join(rows) or '<p style=color:#888>（无子目录）</p>'
    cur = urllib.parse.quote(rel)
    toggle = (f'<p style="margin-top:1.5rem;font-size:.9rem">'
              f'<a href="/browse?path={cur}">隐藏点目录</a></p>' if show_hidden
              else f'<p style="margin-top:1.5rem;font-size:.9rem;color:#aaa">'
                   f'<a href="/browse?path={cur}&all=1">显示隐藏目录</a></p>')
    return (
        PAGE_HEAD
        + "<style>.row{display:block;padding:.7rem .9rem;margin:.35rem 0;border:1px solid #ddd;"
        "border-radius:.5rem;text-decoration:none;color:inherit}</style>"
        + "<h2>📂 选目录起会话</h2>"
        + f'<p style="color:#888;word-break:break-all">{crumb}</p>'
        + '<form method="POST" action="/wake" style="margin:.5rem 0 1.2rem">'
        + f'<input type=hidden name=token value="{safe_tok}">'
        + f'<input type=hidden name=dir value="{html.escape(abs_path)}">'
        + '<button style="font-size:1.15rem;padding:.8rem 1.6rem;border-radius:.6rem;border:0;'
        'background:#d97757;color:#fff">▶ 在此目录唤醒</button>'
        + "</form>"
        + body
        + toggle
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

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra_headers=None):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    @staticmethod
    def _cookie(tok):
        """种 token 到 HttpOnly + SameSite=Strict Cookie：之后导航链接不必带 token
        （不污染浏览历史），且挡跨站 CSRF。"""
        return ("Set-Cookie",
                f"cwtok={urllib.parse.quote(tok)}; Path=/; HttpOnly; "
                "SameSite=Strict; Max-Age=86400")

    def _cookie_token(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "cwtok":
                return urllib.parse.unquote(v)
        return ""

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

        tok = self._header_token() or q.get("token", [""])[0] or self._cookie_token()
        if not token_ok(tok):
            return self._send(401, "unauthorized\n", "text/plain; charset=utf-8")

        if path in ("/", "/wake"):
            st = run_wake("status", timeout=10).stdout
            return self._send(200, landing_page(tok, st), extra_headers=[self._cookie(tok)])
        if path == "/browse":
            target = resolve_in_root(q.get("path", [""])[0])
            if target is None:
                return self._send(400, "bad path\n", "text/plain; charset=utf-8")
            show_hidden = q.get("all", [""])[0] == "1"
            return self._send(200, browse_page(tok, target, show_hidden),
                              extra_headers=[self._cookie(tok)])
        if path == "/dirs":
            # 扁平的名字数组，给 Shortcut「Choose from List」直接用；名字→路径由 /wake 解析
            return self._send(
                200, json.dumps(sorted(list_project_dirs().keys()), ensure_ascii=False),
                "application/json; charset=utf-8",
            )
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

        tok = (self._header_token() or form.get("token", [""])[0]
               or q.get("token", [""])[0] or self._cookie_token())
        if not token_ok(tok):
            return self._send(401, "unauthorized\n", "text/plain; charset=utf-8")

        if path in ("/", "/wake"):
            # Shortcut / API 客户端带 Accept: application/json（或 ?format=json）→ 回 JSON
            wants_json = (
                "application/json" in self.headers.get("Accept", "")
                or q.get("format", [""])[0] == "json"
                or form.get("format", [""])[0] == "json"
            )
            d = form.get("dir", [""])[0] or q.get("dir", [""])[0]
            if d:
                # 安全：绝对路径（/browse 表单给的）必须 realpath 后落在 BROWSE_ROOT 内；
                # 否则当作 /dirs 仓库名解析。两者都不通过就拒绝——杜绝 dir=/etc 这类越界。
                if d.startswith("/"):
                    rd = os.path.realpath(d)
                    if not in_root(rd) or not os.path.isdir(rd):
                        return self._send(403, "dir outside root\n",
                                          "text/plain; charset=utf-8")
                    d = rd
                else:
                    d = list_project_dirs().get(d, "")
                    if not d:
                        return self._send(400, "unknown dir\n",
                                          "text/plain; charset=utf-8")
            args = ["wake"] + ([d] if d else [])
            try:
                out = run_wake(*args)
            except subprocess.TimeoutExpired:
                if wants_json:
                    return self._send(504, json.dumps({"error": "wake timed out"}),
                                      "application/json; charset=utf-8")
                return self._send(504, "wake timed out\n", "text/plain; charset=utf-8")
            if out.returncode == 0:
                url = out.stdout.strip()
                if wants_json:
                    return self._send(200, json.dumps({"url": url}),
                                      "application/json; charset=utf-8")
                return self._send(200, result_page(url).replace("__T__", html.escape(tok)))
            if wants_json:
                return self._send(500, json.dumps({"error": out.stderr.strip()}),
                                  "application/json; charset=utf-8")
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
