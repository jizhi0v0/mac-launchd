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
  GET  /app [/...]            → Next + shadcn 静态导出 SPA（web/out）。入口 /app 鉴权+种 Cookie，
                                /app/<资源> 公开。数据走下面 /api/*。
  GET  /api/browse [?path=]   → 目录 JSON（给 SPA）：{rel,crumb,parent,atRoot,dirs[],showHidden}。同样限根。
  POST /api/wake [path=|dir=] → 同 POST /wake，但恒回 JSON {url}（阻塞式，Shortcut/CLI 用）。
  POST /api/wake/start        → 起一个【独立】会话【立刻返回】{job,rc,dir}，不阻塞、不等 URL。
                                多会话：可并存任意多个，互不影响。
  GET  /api/wake/sessions     → 所有 live 会话的实时状态数组：[{id,rc,dir,phase,elapsed,url,tail[]}]。
                                phase：booting(冷启动)→rendering(注册 RC)→ready(拿到链接)；
                                无超时——卡住就一直停在某 phase，由用户对那一个 kill。
  POST /api/wake/kill?job=    → 精准收掉某一个会话（本地进程 + 注销云端登记），不动其它。
  GET  /status                → 所有 live 会话的链接（多会话）。无副作用。
  GET  /health                → ok（不鉴权，给 tailscale/监控探活）。

实际起会话的脏活全在 claude-wake.sh（WAKE_SH 指过去）。
"""
import html
import hmac
import json
import mimetypes
import os
import re
import secrets
import subprocess
import sys
import threading
import time
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
# Next 静态导出（output: export, basePath /app）的产物目录，由本 server 托管在 /app 下。
WEB_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "out")


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


# ---- 流式唤醒 job 台账 ----
# 模型：POST /api/wake/start 起一个【后台】会话立刻返回 job_id（claude 留在 host server 里跑）；
# 前端不断 GET /api/wake/poll?job= 拿"详细具体链路"（冷启动→TUI→注册 RC→拿到链接）+ 终端尾巴；
# 没有超时——卡住就一直停在某 phase，由用户 POST /api/wake/kill?job= 远程收掉。
# 进度全由 server 端轮询 wake.sh peek/alive 推断，wake.sh 只提供原子动作（见其 spawn-bg/peek/alive）。
URL_RE = re.compile(r"https://claude\.ai/code/session_[A-Za-z0-9_]+")
# 记账：sid(=wake.sh 的 <id>) -> {dir, rc, started, url}。started 用于算 elapsed；url 一旦见过
# 就记住（TUI 里链接会滚走，别让"就绪"又退回"注册中"）。server 重启会丢，但 wake.sh list 从
# tmux 读才是 live 真相，丢的只是 elapsed/记忆 url，list_sessions 里会按需补登记。
JOBS = {}
JOBS_LOCK = threading.Lock()
JOBS_MAX = 24


def register_job(sid, rc, d):
    with JOBS_LOCK:
        JOBS[sid] = {"dir": d, "rc": rc, "started": time.time(), "url": None}
        if len(JOBS) > JOBS_MAX:  # 修剪最旧（started 可能为 None → 视作 0 排最前先删）
            for old in sorted(JOBS, key=lambda k: JOBS[k]["started"] or 0)[:-JOBS_MAX]:
                JOBS.pop(old, None)


def classify(pane):
    """据 pane 内容推断 phase + url + 终端尾巴。
       booting(空白·冷启动中) → rendering(TUI 起来了·注册 RC 等 URL) → ready(拿到链接)；
       failed = RC 注册失败 banner。只有 live 会话才会被分类（list 来自 tmux 在跑的会话）。"""
    low = pane.lower()
    m = URL_RE.search(pane)
    lines = [ln for ln in pane.splitlines() if ln.strip()]
    if m:
        phase = "ready"
    elif "session creation failed" in low or "remote control failed" in low:
        phase = "failed"
    elif len(lines) >= 2:
        phase = "rendering"
    else:
        phase = "booting"
    return phase, (m.group(0) if m else None), lines[-8:]


def parse_dump(out):
    """把 wake.sh dump 的输出切成 [(sid, rc, dir, pane), ...]。
       哨兵行 '@@CW\\tid\\trc\\tdir' 起一段，之后到下一个哨兵前的所有行都是该会话的 pane。"""
    blocks = []
    cur = None
    pane_lines = []
    for line in out.splitlines():
        if line.startswith("@@CW\t"):
            if cur is not None:
                blocks.append((*cur, "\n".join(pane_lines)))
            parts = line.split("\t")
            cur = (parts[1], parts[2] if len(parts) > 2 else "",
                   parts[3] if len(parts) > 3 else "")
            pane_lines = []
        elif cur is not None:
            pane_lines.append(line)
    if cur is not None:
        blocks.append((*cur, "\n".join(pane_lines)))
    return blocks


def list_sessions():
    """所有 live wake 会话的实时状态数组（给 SPA 列出、各自可 kill）。无超时——卡住就一直停在
       某 phase，由用户对那一个点「收掉」。新的在上。
       一次 dump 拿全量（不再对每个会话单独 spawn wake.sh）：会话多 + 轮询叠加时，per-session
       spawn 会让 tmux 命令排队、延迟雪崩（实测 8s→22s 一路涨），轮询彻底卡死。"""
    out = run_wake("dump", timeout=15).stdout
    res = []
    for sid, rc, d, pane in parse_dump(out):
        if not sid:
            continue
        phase, url, tail = classify(pane)
        with JOBS_LOCK:
            j = JOBS.get(sid)
            if j is None:  # server 重启后 / Shortcut 起的会话：补登记，以便记住 url
                j = JOBS[sid] = {"dir": d, "rc": rc, "started": None, "url": None}
            started, known = j["started"], j["url"]
            if url:
                j["url"] = url
        if not url and known:  # URL 在 TUI 里滚走了，用记住的，别退回"注册中"
            url, phase = known, "ready"
        # rel = 相对 BROWSE_ROOT 的路径（给前端按目录分组 / 点头跳到该目录 / 在该组再唤醒）。
        # 不在根内（如默认的 /tmp/claude-wake-cwd）→ None：前端据此走"默认目录"重唤醒、组头不可点。
        rel = None
        if d == BROWSE_ROOT:
            rel = ""
        elif d.startswith(BROWSE_ROOT + os.sep):
            rel = os.path.relpath(d, BROWSE_ROOT)
        res.append({
            "id": sid, "rc": rc, "dir": d, "rel": rel, "phase": phase, "url": url,
            "tail": tail, "elapsed": int(time.time() - started) if started else None,
        })
    res.sort(key=lambda x: (x["elapsed"] is None, -(x["elapsed"] or 0)))
    return res


# 防雪崩第二道：多客户端/多标签同时轮询时，用锁+短缓存把并发请求收敛成"每 ~0.8s 至多一次 dump"。
# 缓存窗口 < 前端 1.5s 间隔，单标签每次仍拿到新数据；锁让并发请求排队而不是各自 spawn 一堆。
_SESS_CACHE = {"at": 0.0, "data": []}
_SESS_LOCK = threading.Lock()


def list_sessions_cached():
    with _SESS_LOCK:
        if time.time() - _SESS_CACHE["at"] < 0.8:
            return _SESS_CACHE["data"]
        data = list_sessions()
        _SESS_CACHE.update(at=time.time(), data=data)
        return data


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
        + '<p style="margin-top:1.2rem"><a href="/app">🖥️ 桌面版（Next + shadcn）</a>'
        + ' · <a href="/browse">📂 纯 HTML 浏览</a></p>'
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


def browse_json(abs_path, show_hidden=False):
    """给 Next SPA 用的目录 JSON：当前相对路径、上级、子目录名列表。abs_path 须已限根。"""
    rel = "" if abs_path == BROWSE_ROOT else os.path.relpath(abs_path, BROWSE_ROOT)
    return {
        "rel": rel,
        "crumb": "~/" + rel if rel else "~",
        "parent": None if abs_path == BROWSE_ROOT else os.path.dirname(rel),
        "atRoot": abs_path == BROWSE_ROOT,
        "dirs": list_subdirs(abs_path, show_hidden),
        "showHidden": show_hidden,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-wake"
    # HTTP/1.1 → keep-alive：浏览器复用少数几条连接，而不是硬刷新时一次性开十几条。
    # 所有响应都带 Content-Length（_send / _serve_web 都设了），keep-alive 不会错位。
    protocol_version = "HTTP/1.1"
    timeout = 30  # 闲置 keep-alive 连接 30s 自动断，别让线程一直挂着

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

    def _serve_web(self, rel, cookie_tok=None):
        """托管 Next 静态导出（web/out）。限死在 WEB_OUT 内（防穿越）。
        入口 index.html 传 cookie_tok → 顺带种鉴权 Cookie；资源类公开。"""
        target = os.path.realpath(os.path.join(WEB_OUT, rel))
        if not (target == WEB_OUT or target.startswith(WEB_OUT + os.sep)) \
                or not os.path.isfile(target):
            return self._send(404, "前端未构建（cd web && bun run build）\n",
                              "text/plain; charset=utf-8")
        ctype = mimetypes.guess_type(target)[0] or "application/octet-stream"
        with open(target, "rb") as f:
            b = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        # 入口 html 不缓存（保证鉴权/Cookie 每次走）；指纹化的静态资源可长缓存
        self.send_header("Cache-Control",
                         "no-store" if cookie_tok else "public, max-age=31536000")
        if cookie_tok:
            k, v = self._cookie(cookie_tok)
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

    def _resolve_wake_dir(self, form, q):
        """解析唤醒目标目录。SPA 传相对根的 path=；旧客户端（Shortcut/HTML 表单）传 dir=
        （绝对路径或 /dirs 仓库名）。返回 (abs_dir, None)；abs_dir="" 表示用默认目录。
        出错返回 (None, (code, body, ctype))，调用方直接 _send(*err)。"""
        rel = form.get("path", [""])[0] or q.get("path", [""])[0]
        d = form.get("dir", [""])[0] or q.get("dir", [""])[0]
        if rel and not d:
            abs_dir = resolve_in_root(rel)
            if abs_dir is None:
                return None, (400, json.dumps({"error": "bad path"}),
                              "application/json; charset=utf-8")
            return abs_dir, None
        if d:
            # 安全：绝对路径必须 realpath 后落在 BROWSE_ROOT 内（杜绝 dir=/etc 越界）；
            # 否则当作 /dirs 仓库名解析。两者都不通过就拒。
            if d.startswith("/"):
                rd = os.path.realpath(d)
                if not in_root(rd) or not os.path.isdir(rd):
                    return None, (403, "dir outside root\n", "text/plain; charset=utf-8")
                return rd, None
            dd = list_project_dirs().get(d, "")
            if not dd:
                return None, (400, "unknown dir\n", "text/plain; charset=utf-8")
            return dd, None
        return "", None  # 没给 → 默认目录（wake.sh 用 WAKE_DIR_DEFAULT）

    # ---- GET：只读，绝不 spawn ----
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        q = urllib.parse.parse_qs(parsed.query)

        if path in ("/health", "/healthz"):
            return self._send(200, "ok\n", "text/plain; charset=utf-8")

        # /app/<资源>：Next SPA 外壳（无密钥）公开托管，免 token —— 否则浏览器拉不到 JS/CSS。
        # 数据全在下面 /api/*（要 token）后面，外壳公开不泄露任何东西。入口 /app 仍鉴权（见下）。
        if path.startswith("/app/"):
            return self._serve_web(path[len("/app/"):])

        tok = self._header_token() or q.get("token", [""])[0] or self._cookie_token()
        if not token_ok(tok):
            return self._send(401, "unauthorized\n", "text/plain; charset=utf-8")

        if path == "/app":
            # SPA 入口：鉴权 + 顺带种 Cookie，之后 /api/* 靠 Cookie 同源放行
            return self._serve_web("index.html", cookie_tok=tok)
        if path == "/api/wake/sessions":
            return self._send(200, json.dumps(list_sessions_cached(), ensure_ascii=False),
                              "application/json; charset=utf-8",
                              extra_headers=[self._cookie(tok)])
        if path == "/api/browse":
            target = resolve_in_root(q.get("path", [""])[0])
            if target is None:
                return self._send(400, json.dumps({"error": "bad path"}),
                                  "application/json; charset=utf-8")
            show_hidden = q.get("all", [""])[0] == "1"
            return self._send(
                200, json.dumps(browse_json(target, show_hidden), ensure_ascii=False),
                "application/json; charset=utf-8", extra_headers=[self._cookie(tok)])
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

        # ---- 流式唤醒（SPA 用）：起会话立刻返回 job_id，前端轮询 /api/wake/poll 看链路 ----
        if path == "/api/wake/start":
            d, err = self._resolve_wake_dir(form, q)
            if err:
                return self._send(*err)
            try:
                r = run_wake("spawn-bg", *([d] if d else []), timeout=30)
            except subprocess.TimeoutExpired:
                return self._send(504, json.dumps({"error": "spawn 超时"}),
                                  "application/json; charset=utf-8")
            if r.returncode != 0:
                # 最常见：host server 没在跑（应由登录项保活）→ wake.sh die 的原因在 stderr
                return self._send(500, json.dumps({"error": r.stderr.strip() or "spawn 失败"}),
                                  "application/json; charset=utf-8")
            sid, rc, dd = "", "", d
            for ln in r.stdout.splitlines():
                if ln.startswith("id="):
                    sid = ln[3:].strip()
                elif ln.startswith("rc="):
                    rc = ln[3:].strip()
                elif ln.startswith("dir="):
                    dd = ln[4:].strip()
            register_job(sid, rc, dd)
            return self._send(200, json.dumps({"job": sid, "rc": rc, "dir": dd}),
                              "application/json; charset=utf-8")

        # ---- 远程 kill：精准收掉【某一个】会话（本地进程 + 让 claude 注销云端登记），不动其它 ----
        if path == "/api/wake/kill":
            jid = form.get("job", [""])[0] or q.get("job", [""])[0]
            rc = ""
            with JOBS_LOCK:
                j = JOBS.get(jid)
                if j:
                    rc = j.get("rc", "")
            if jid:
                try:
                    run_wake("reap", jid, *([rc] if rc else []), timeout=20)
                except subprocess.TimeoutExpired:
                    pass
                with JOBS_LOCK:
                    JOBS.pop(jid, None)
            return self._send(200, json.dumps({"ok": True}),
                              "application/json; charset=utf-8")

        # ---- 全部收掉：一键清空所有 live 会话（多会话攒多了时方便）----
        if path == "/api/wake/reap-all":
            try:
                run_wake("reap-all", timeout=30)
            except subprocess.TimeoutExpired:
                pass
            with JOBS_LOCK:
                JOBS.clear()
            return self._send(200, json.dumps({"ok": True}),
                              "application/json; charset=utf-8")

        if path in ("/", "/wake", "/api/wake"):
            # Shortcut / API 带 Accept: application/json（或 ?format=json，或走 /api/wake）→ 回 JSON。
            # 这是【阻塞式】老路径：起会话 + 等到 URL 一次性返回（45s 内）。Shortcut/CLI 用它；
            # SPA 改走上面的 start/poll/kill 流式三件套。
            wants_json = (
                path == "/api/wake"
                or "application/json" in self.headers.get("Accept", "")
                or q.get("format", [""])[0] == "json"
                or form.get("format", [""])[0] == "json"
            )
            d, err = self._resolve_wake_dir(form, q)
            if err:
                return self._send(*err)
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


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    # 默认监听 backlog 只有 5——硬刷新一次并发开十几条连接就溢出、被拒（curl 000 / tailscale 502）。
    # 调大到 128，让突发连接排队而不是被拒。
    request_queue_size = 128


def main():
    if not TOKEN:
        sys.exit(f"[claude-wake] no token at {TOKEN_FILE} — 先跑 install.sh")
    if not WAKE_SH or not os.path.exists(WAKE_SH):
        sys.exit(f"[claude-wake] WAKE_SH 未设置或不存在: {WAKE_SH!r}")
    print(f"[claude-wake] listening on {HOST}:{PORT} (wake={WAKE_SH})", flush=True)
    Server((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
