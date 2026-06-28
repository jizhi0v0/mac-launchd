"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CheckCircle2,
  ChevronRight,
  ChevronUp,
  Circle,
  ExternalLink,
  Eye,
  EyeOff,
  Folder,
  Loader2,
  Moon,
  Play,
  Plus,
  RotateCw,
  Search,
  Square,
  Sun,
  Terminal,
} from "lucide-react";

import {
  browse,
  wakeKill,
  wakeReapAll,
  wakeSessions,
  wakeStart,
  type BrowseData,
  type WakeSession,
} from "@/lib/api";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

function readPath() {
  if (typeof window === "undefined") return "";
  return new URLSearchParams(window.location.search).get("p") || "";
}

const basename = (p: string) => p.replace(/\/+$/, "").split("/").pop() || p || "~";

// 进度链路（每个会话独立走）：起会话即完成 step0；booting→step1，rendering→step3(注册 RC)，ready→全完成。
const STEPS = ["起 claude", "冷启动 · 等 TUI", "TUI 渲染", "注册 RC 云连接", "拿到接管链接"];
function activeStep(phase: WakeSession["phase"]): number {
  if (phase === "ready") return STEPS.length;
  if (phase === "rendering") return 3;
  return 1;
}
function phaseMeta(p: WakeSession["phase"]) {
  switch (p) {
    case "ready":
      return { label: "已就绪", dot: "bg-green-500", pulse: false };
    case "failed":
      return { label: "注册失败", dot: "bg-destructive", pulse: false };
    case "rendering":
      return { label: "注册 RC…", dot: "bg-amber-500", pulse: true };
    default:
      return { label: "冷启动…", dot: "bg-amber-500", pulse: true };
  }
}

type Pending = { id: string; rc: string; dir: string; rel: string | null; started: number };

export default function Page() {
  const [path, setPath] = useState("");
  const [all, setAll] = useState(false);
  const [data, setData] = useState<BrowseData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [polled, setPolled] = useState<WakeSession[]>([]);
  const [pending, setPending] = useState<Pending[]>([]);
  const [starting, setStarting] = useState<Set<string>>(new Set());
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [wakeErr, setWakeErr] = useState<string | null>(null);
  const [dark, setDark] = useState(true);
  const loadSeq = useRef(0);

  useEffect(() => {
    setPath(readPath());
    const t = localStorage.getItem("cw-theme");
    if (t) {
      const d = t === "dark";
      setDark(d);
      document.documentElement.classList.toggle("dark", d);
    }
    const onPop = () => setPath(readPath());
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  const load = useCallback((p: string, showAll: boolean) => {
    // 抢占式序号：只让最新一次 browse 落地（深链接挂载会同时发根+深两个请求，谁后返回谁覆盖
    // data，导致 data=根列表/path=深路径错配，点进去把根文件夹拼到深 path 后面 → bad path）。
    const seq = ++loadSeq.current;
    setLoading(true);
    setError(null);
    browse(p, showAll)
      .then((d) => seq === loadSeq.current && setData(d))
      .catch((e) => seq === loadSeq.current && setError(String(e?.message || e)))
      .finally(() => seq === loadSeq.current && setLoading(false));
  }, []);

  useEffect(() => {
    load(path, all);
  }, [path, all, load]);

  // 会话轮询：无超时，每 1.5s 抓所有 live 会话状态。单次失败不清空列表。
  const refreshSessions = useCallback(async () => {
    try {
      const s = await wakeSessions();
      setPolled(s);
      setPending((p) => p.filter((x) => !s.some((y) => y.id === x.id)));
    } catch {
      /* 网络抖动：保留上次列表 */
    }
  }, []);
  // 自调度循环（不是 setInterval）：等上一次 poll 完成、再隔 1.5s 发下一次，永不重叠。
  // setInterval 会"到点就发"，一旦单次 >1.5s 就会层层叠加，把 tmux 命令堵到延迟雪崩、UI 卡死。
  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout>;
    const loop = async () => {
      await refreshSessions();
      if (!stop) timer = setTimeout(loop, 1500);
    };
    loop();
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, [refreshSessions]);

  const navigate = useCallback((p: string) => {
    setFilter("");
    const params = new URLSearchParams();
    if (p) params.set("p", p);
    const token = new URLSearchParams(window.location.search).get("token");
    if (token) params.set("token", token);
    const qs = params.toString();
    window.history.pushState({ p }, "", qs ? `?${qs}` : window.location.pathname);
    setPath(p);
  }, []);

  // 唤醒：起一个独立会话；起好后乐观占位、自动展开看进度，轮询接上真实状态。
  const doWake = useCallback(
    async (target: string, key: string) => {
      setWakeErr(null);
      setStarting((s) => new Set(s).add(key));
      try {
        const r = await wakeStart(target);
        setPending((prev) => [
          { id: r.job, rc: r.rc, dir: r.dir, rel: target.startsWith("/") ? null : target || null, started: Date.now() },
          ...prev,
        ]);
        setExpandedId(r.job);
        refreshSessions();
      } catch (e) {
        setWakeErr(String((e as Error)?.message || e));
      } finally {
        setStarting((s) => {
          const n = new Set(s);
          n.delete(key);
          return n;
        });
      }
    },
    [refreshSessions],
  );

  const doKill = useCallback(
    async (id: string) => {
      setPending((p) => p.filter((x) => x.id !== id));
      setPolled((p) => p.filter((x) => x.id !== id));
      try {
        await wakeKill(id);
      } catch {
        /* 尽力而为 */
      }
      refreshSessions();
    },
    [refreshSessions],
  );

  const doKillAll = useCallback(async () => {
    setPending([]);
    setPolled([]);
    try {
      await wakeReapAll();
    } catch {
      /* 尽力而为 */
    }
    refreshSessions();
  }, [refreshSessions]);

  const toggleTheme = () => {
    const d = !dark;
    setDark(d);
    document.documentElement.classList.toggle("dark", d);
    localStorage.setItem("cw-theme", d ? "dark" : "light");
  };

  const dirs = useMemo(() => {
    const list = data?.dirs ?? [];
    const f = filter.trim().toLowerCase();
    return f ? list.filter((d) => d.toLowerCase().includes(f)) : list;
  }, [data, filter]);

  const sessions = useMemo(() => {
    const map = new Map<string, WakeSession>();
    for (const p of pending)
      map.set(p.id, {
        id: p.id,
        rc: p.rc,
        dir: p.dir,
        rel: p.rel,
        phase: "booting",
        elapsed: Math.floor((Date.now() - p.started) / 1000),
        url: null,
        tail: [],
      });
    for (const s of polled) map.set(s.id, s);
    return [...map.values()].sort((a, b) => (a.elapsed ?? 1e9) - (b.elapsed ?? 1e9));
  }, [pending, polled]);

  // 按目录分组（claude app 左栏样式）。组顺序 = 会话顺序（新的在前）。
  const groups = useMemo(() => {
    const m = new Map<string, { dir: string; rel: string | null; list: WakeSession[] }>();
    for (const s of sessions) {
      const g = m.get(s.dir) ?? { dir: s.dir, rel: s.rel, list: [] };
      g.list.push(s);
      m.set(s.dir, g);
    }
    return [...m.values()];
  }, [sessions]);

  // 子目录路径基于 data.rel（当前真正展示的列表所属路径），不用 path（可能是还在加载的目标）。
  const here = data?.rel ?? "";
  const child = (name: string) => (here ? `${here}/${name}` : name);

  return (
    <main className="mx-auto w-full max-w-6xl px-4 py-6 sm:py-10">
      <header className="mb-6 flex items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">🛟 claude-wake</h1>
          <p className="text-muted-foreground text-sm">选个目录，远程起一个 claude 会话</p>
        </div>
        <Button variant="ghost" size="icon" onClick={toggleTheme} title="切换主题">
          {dark ? <Sun /> : <Moon />}
        </Button>
      </header>

      {wakeErr && (
        <div className="border-destructive/40 text-destructive mb-5 rounded-lg border px-4 py-3 text-sm">
          唤醒失败：{wakeErr}
        </div>
      )}

      <div className="flex flex-col gap-6 md:flex-row md:items-start">
        {/* 左栏：会话 + 正在发起的占位（无任何动静时不占位，浏览器吃满宽） */}
        {(sessions.length > 0 || starting.size > 0) && (
          <aside className="flex flex-col gap-2 md:w-72 md:shrink-0">
            <div className="flex items-center justify-between px-1">
              <h2 className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
                进行中 · {sessions.length + starting.size}
              </h2>
              {sessions.length > 1 && (
                <button
                  onClick={doKillAll}
                  className="text-muted-foreground hover:text-destructive text-xs"
                >
                  全部收掉
                </button>
              )}
            </div>
            {/* 起会话请求在飞、还没拿到 id 时的即时占位——别让点了之后左侧一片空白看着像没反应 */}
            {[...starting].map((key) => (
              <div
                key={"starting-" + key}
                className="bg-card text-muted-foreground flex items-center gap-2 rounded-lg border px-2.5 py-2 text-sm"
              >
                <Loader2 className="size-3.5 shrink-0 animate-spin text-amber-500" />
                <span className="truncate">
                  起会话中…{key === "." ? "" : ` ${basename(key.replace(/^\+/, ""))}`}
                </span>
              </div>
            ))}
            {groups.map((g) => (
              <div key={g.dir} className="bg-card overflow-hidden rounded-lg border">
                <div className="flex items-center justify-between gap-1 border-b px-2.5 py-1.5">
                  <button
                    onClick={() => g.rel != null && navigate(g.rel)}
                    disabled={g.rel == null}
                    title={g.dir}
                    className="hover:text-primary truncate text-left text-sm font-medium disabled:cursor-default disabled:hover:text-current"
                  >
                    {basename(g.dir)}
                  </button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="size-7 shrink-0"
                    title="在此目录再唤醒一个"
                    disabled={starting.has("+" + g.dir)}
                    onClick={() => doWake(g.rel ?? "", "+" + g.dir)}
                  >
                    {starting.has("+" + g.dir) ? (
                      <Loader2 className="animate-spin" />
                    ) : (
                      <Plus />
                    )}
                  </Button>
                </div>
                <div className="flex flex-col">
                  {g.list.map((s) => (
                    <SessionRow
                      key={s.id}
                      s={s}
                      expanded={expandedId === s.id}
                      onToggle={() => setExpandedId((id) => (id === s.id ? null : s.id))}
                      onKill={() => doKill(s.id)}
                    />
                  ))}
                </div>
              </div>
            ))}
          </aside>
        )}

        {/* 主区：文件浏览器 */}
        <div className="min-w-0 flex-1">
          <div className="mb-4 flex flex-wrap items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={!data || data.atRoot || loading}
              onClick={() => data?.parent != null && navigate(data.parent)}
            >
              <ChevronUp /> 上级
            </Button>
            <nav className="bg-muted text-muted-foreground flex min-w-0 flex-1 items-center gap-1 overflow-x-auto rounded-md px-2.5 py-1.5 text-xs whitespace-nowrap">
              <button
                onClick={() => navigate("")}
                disabled={loading}
                className="hover:text-foreground shrink-0 disabled:pointer-events-none"
              >
                ~
              </button>
              {(data?.rel ? data.rel.split("/") : []).map((seg, i, arr) => {
                const target = arr.slice(0, i + 1).join("/");
                const isLast = i === arr.length - 1;
                return (
                  <span key={target} className="flex shrink-0 items-center gap-1">
                    <span className="opacity-40">/</span>
                    {isLast ? (
                      <span className="text-foreground">{seg}</span>
                    ) : (
                      <button
                        onClick={() => navigate(target)}
                        disabled={loading}
                        className="hover:text-foreground disabled:pointer-events-none"
                      >
                        {seg}
                      </button>
                    )}
                  </span>
                );
              })}
            </nav>
            <Button variant="outline" size="sm" onClick={() => load(path, all)} title="刷新">
              <RotateCw className={cn(loading && "animate-spin")} />
            </Button>
            <Button variant="outline" size="sm" onClick={() => setAll((v) => !v)}>
              {all ? <EyeOff /> : <Eye />}
              {all ? "隐藏点目录" : "显示隐藏"}
            </Button>
            <Button size="sm" disabled={starting.has(".")} onClick={() => doWake(here, ".")}>
              {starting.has(".") ? <Loader2 className="animate-spin" /> : <Play />}
              在此唤醒
            </Button>
          </div>

          <div className="relative mb-4">
            <Search className="text-muted-foreground absolute top-1/2 left-3 size-4 -translate-y-1/2" />
            <input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="过滤当前目录…"
              className="border-input bg-background focus-visible:ring-ring/50 h-9 w-full rounded-md border pr-3 pl-9 text-sm outline-none focus-visible:ring-[3px]"
            />
          </div>

          {error ? (
            <div className="border-destructive/40 text-destructive flex items-center justify-between gap-3 rounded-lg border px-4 py-3 text-sm">
              <span className="min-w-0 break-words">{error}</span>
              <Button variant="outline" size="sm" onClick={() => load(path, all)}>
                <RotateCw /> 重试
              </Button>
            </div>
          ) : loading && !data ? (
            <div className="text-muted-foreground flex items-center gap-2 px-1 py-8 text-sm">
              <Loader2 className="animate-spin" /> 加载中…
            </div>
          ) : dirs.length === 0 ? (
            <p className="text-muted-foreground px-1 py-8 text-sm">（无子目录）</p>
          ) : (
            <div
              className={cn(
                "grid grid-cols-1 gap-2 sm:grid-cols-2",
                loading && "pointer-events-none opacity-50",
              )}
            >
              {dirs.map((name) => {
                const cp = child(name);
                const busy = starting.has(cp);
                return (
                  <div
                    key={name}
                    className="group bg-card hover:border-ring/60 flex items-center gap-1 rounded-lg border pr-1 transition-colors"
                  >
                    <button
                      onClick={() => navigate(cp)}
                      className="flex min-w-0 flex-1 items-center gap-2.5 px-3 py-2.5 text-left text-sm"
                    >
                      <Folder className="text-muted-foreground size-4 shrink-0" />
                      <span className="truncate">{name}</span>
                    </button>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-8 opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
                      disabled={busy}
                      title={`在 ${name} 唤醒`}
                      onClick={() => doWake(cp, cp)}
                    >
                      {busy ? <Loader2 className="animate-spin" /> : <Play />}
                    </Button>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      <footer className="text-muted-foreground/70 mt-10 text-center text-xs">
        限根 $HOME · 可并存多个会话 · Next 16.3 preview + shadcn ·{" "}
        <a className="underline" href="/browse">
          纯 HTML 版
        </a>
      </footer>
    </main>
  );
}

// 会话行：紧凑（状态点 + 文案 + 秒数），点开看详细链路/终端/接管链接，永远有「收掉」。
function SessionRow({
  s,
  expanded,
  onToggle,
  onKill,
}: {
  s: WakeSession;
  expanded: boolean;
  onToggle: () => void;
  onKill: () => void;
}) {
  const meta = phaseMeta(s.phase);
  const ai = activeStep(s.phase);
  return (
    <div className="border-b last:border-b-0">
      <button
        onClick={onToggle}
        className="hover:bg-muted/50 flex w-full items-center gap-2 px-2.5 py-2 text-left text-sm"
      >
        <span
          className={cn("size-2 shrink-0 rounded-full", meta.dot, meta.pulse && "animate-pulse")}
        />
        <span className="flex-1 truncate">{meta.label}</span>
        {s.elapsed != null && (
          <span className="text-muted-foreground text-xs">{s.elapsed}s</span>
        )}
        <ChevronRight
          className={cn("text-muted-foreground size-3.5 transition-transform", expanded && "rotate-90")}
        />
      </button>

      {expanded && (
        <div className="flex flex-col gap-2.5 px-2.5 pt-0 pb-3">
          <p className="text-muted-foreground font-mono text-[10px] break-all">{s.rc}</p>

          {s.phase === "ready" && s.url ? (
            <>
              <a
                href={s.url}
                target="_blank"
                rel="noreferrer"
                className="text-muted-foreground hover:text-foreground font-mono text-[11px] break-all underline"
              >
                {s.url}
              </a>
              <Button size="sm" onClick={() => window.open(s.url!, "_blank")}>
                <ExternalLink /> 在 Claude 接管
              </Button>
            </>
          ) : s.phase === "failed" ? (
            <p className="text-destructive text-xs">
              RC 注册失败：claude 起来了但云连接被拒（多为 keychain 登录态失效，需本机重登一次）。
            </p>
          ) : (
            <>
              <ol className="flex flex-col gap-1 text-xs">
                {STEPS.map((label, i) => {
                  const done = i < ai;
                  const running = i === ai;
                  return (
                    <li
                      key={label}
                      className={cn(
                        "flex items-center gap-1.5",
                        running && "text-foreground font-medium",
                        !done && !running && "text-muted-foreground/50",
                      )}
                    >
                      {done ? (
                        <CheckCircle2 className="text-primary size-3.5 shrink-0" />
                      ) : running ? (
                        <Loader2 className="text-primary size-3.5 shrink-0 animate-spin" />
                      ) : (
                        <Circle className="size-3.5 shrink-0" />
                      )}
                      {label}
                    </li>
                  );
                })}
              </ol>
              {s.tail.length > 0 && (
                <pre className="bg-muted/60 text-muted-foreground max-h-40 overflow-auto rounded-md p-2 font-mono text-[10px] leading-relaxed">
                  <span className="text-muted-foreground/60 mb-1 flex items-center gap-1.5">
                    <Terminal className="size-3" /> 终端
                  </span>
                  {s.tail.join("\n")}
                </pre>
              )}
            </>
          )}

          <Button variant="destructive" size="sm" className="self-start" onClick={onKill}>
            <Square /> 收掉
          </Button>
        </div>
      )}
    </div>
  );
}
