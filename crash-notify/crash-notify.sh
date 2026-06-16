#!/bin/bash
# crash-notify —— 监听 macOS 崩溃报告 + 指定私有 dump 目录,有新崩溃即弹本地横幅。
#
# 由 LaunchAgent 的 WatchPaths 触发:被监听目录一有变化就跑一次,扫出"上次以来的新崩溃",
# 弹 terminal-notifier 横幅,然后退出。常驻零开销。
#
# 覆盖两类:
#   1) 走系统崩溃报告的 app(Codex、绝大多数原生 app) -> ~/.../DiagnosticReports/*.ips
#   2) 自带崩溃处理器(Breakpad/Crashpad)的 app(ToDesk、Chrome/Electron) -> 各自私有 dump 目录
#
# 防崩溃循环刷屏:同一进程两条横幅最短间隔 COOLDOWN 秒;单次扫描内同进程崩溃数
#               >= LOOP_THRESHOLD 判为"崩溃循环",合并成一条横幅。
#
# 用法: crash-notify.sh          正常扫描+通知(由 launchd 调)
#       crash-notify.sh seed     仅把当前所有崩溃记为已读、不通知(install 时打基线用)
set -uo pipefail

# ---------------- 配置 ----------------
export CN_NOTIFIER="/opt/homebrew/bin/terminal-notifier"
export CN_LOG="$HOME/Library/Logs/crash-notify.log"
export CN_STATE="$HOME/Library/Application Support/crash-notify/state.json"
export CN_COOLDOWN=300        # 同进程两次横幅最短间隔(秒)
export CN_LOOP_THRESHOLD=5    # 单次扫描同进程崩溃数 >= 此值 => 崩溃循环

# Apple 崩溃报告目录(*.ips)。换行分隔。
export CN_IPS_DIRS="$HOME/Library/Logs/DiagnosticReports
/Library/Logs/DiagnosticReports"

# 私有 dump 目录,格式 "目录|显示名|扩展名"。换行分隔。
# 每加一行,记得把同一个目录同步加到 com.jizhi.crash-notify.plist 的 WatchPaths,否则不会被触发。
export CN_DUMP_DIRS="/Library/Application Support/ToDesk/dumps|ToDesk|dmp"

export CN_SEED="${1:-}"

mkdir -p "$(dirname "$CN_STATE")" "$(dirname "$CN_LOG")"

python3 <<'PY'
import os, sys, json, time, glob, subprocess, fcntl

STATE   = os.environ["CN_STATE"]
LOG     = os.environ["CN_LOG"]
NOTIFIER= os.environ["CN_NOTIFIER"]
COOLDOWN= int(os.environ["CN_COOLDOWN"])
LOOP_TH = int(os.environ["CN_LOOP_THRESHOLD"])
IPS_DIRS  = [d for d in os.environ["CN_IPS_DIRS"].splitlines() if d.strip()]
DUMP_DIRS = [l for l in os.environ["CN_DUMP_DIRS"].splitlines() if l.strip()]
SEED    = os.environ.get("CN_SEED", "") == "seed"

now = time.time()

# 文件锁:并发触发(手动 + WatchPaths,或快速连续触发)时只让一个实例处理,其余直接退出,
# 避免重复通知 / 状态竞态。macOS 无 flock(1),用 fcntl 自己锁。
_lock = open(STATE + ".lock", "w")
try:
    fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)

def load_state():
    try:
        with open(STATE) as f:
            s = json.load(f)
    except Exception:
        s = {}
    s.setdefault("processed", [])      # 已处理的崩溃文件 basename(有序、封顶)
    s.setdefault("notify_last", {})    # 进程名 -> 上次弹横幅的 epoch
    return s

def save_state(s):
    s["processed"] = s["processed"][-8000:]   # 封顶,防无限增长
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, STATE)

def logline(msg):
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")

def parse_ips(path):
    """返回 (proc, exc) 或 None(非崩溃/解析失败/写一半)。"""
    try:
        raw = open(path, "r", errors="replace").read()
        head, _, body = raw.partition("\n")
        hdr = json.loads(head)
        b   = json.loads(body)
    except Exception:
        return None                       # 可能正在写,留着下次重试(不记 processed)
    exc = b.get("exception")
    if not exc:                           # 没有异常段 => 不是崩溃(hang/wakeups 等),跳过
        return None
    proc = b.get("procName") or hdr.get("app_name") or os.path.basename(path)
    sig  = exc.get("signal") or exc.get("type") or "crash"
    typ  = exc.get("type", "")
    detail = f"{typ} {sig}".strip()
    return proc, detail

state = load_state()
processed = set(state["processed"])
new = {}     # appname -> {"count": n, "detail": str, "kind": "ips"/"dump"}

# 1) Apple 崩溃报告
for d in IPS_DIRS:
    for p in glob.glob(os.path.join(d, "*.ips")):
        name = os.path.basename(p)
        if name in processed:
            continue
        r = parse_ips(p)
        if r is None:
            continue
        processed.add(name); state["processed"].append(name)
        if SEED:
            continue
        proc, detail = r
        e = new.setdefault(proc, {"count": 0, "detail": detail, "kind": "ips"})
        e["count"] += 1

# 2) 私有 dump 目录
for line in DUMP_DIRS:
    try:
        d, label, ext = line.split("|")
    except ValueError:
        continue
    for p in glob.glob(os.path.join(d, f"*.{ext}")):
        name = label + "/" + os.path.basename(p)   # 带 label 前缀,避免跨目录重名
        if name in processed:
            continue
        processed.add(name); state["processed"].append(name)
        if SEED:
            continue
        e = new.setdefault(label, {"count": 0, "detail": "Breakpad/Crashpad dump", "kind": "dump"})
        e["count"] += 1

if SEED:
    save_state(state)
    logline(f"[SEED] 基线已建立,标记 {len(state['processed'])} 个已存在崩溃为已读")
    sys.exit(0)

def notify(title, subtitle, message, group, sound):
    try:
        subprocess.run([NOTIFIER, "-title", title, "-subtitle", subtitle,
                        "-message", message, "-group", group, "-sound", sound],
                       timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as ex:
        logline(f"[WARN] terminal-notifier 失败: {ex}")

for app, e in new.items():
    cnt, detail, kind = e["count"], e["detail"], e["kind"]
    loop = cnt >= LOOP_TH
    tag  = "CRASH-LOOP" if loop else "CRASH"
    logline(f"[{tag}] {app} x{cnt} ({detail})")

    last = state["notify_last"].get(app, 0)
    if now - last < COOLDOWN:
        logline(f"[MUTE] {app} 在 {COOLDOWN}s 冷却内,跳过横幅(仍记日志)")
        continue
    state["notify_last"][app] = now

    if loop:
        title    = f"💥 {app} 崩溃循环"
        subtitle = f"刚刚崩了 {cnt} 次"
        message  = f"{detail} · 疑似崩溃循环,已静音 {COOLDOWN//60} 分钟"
        sound    = "Sosumi"
    else:
        title    = f"💥 {app} 崩溃"
        subtitle = detail
        message  = "查看: ~/Library/Logs/crash-notify.log" if kind == "ips" else f"私有 dump · 共 {cnt} 个"
        sound    = "Basso"
    notify(title, subtitle, message, f"crash-notify-{app}", sound)

save_state(state)
PY
