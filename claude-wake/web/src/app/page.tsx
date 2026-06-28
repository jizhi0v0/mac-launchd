"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  Check,
  CheckCircle2,
  ChevronRight,
  Circle,
  Copy,
  Cpu,
  ExternalLink,
  Eye,
  EyeOff,
  Folder,
  Loader2,
  MemoryStick,
  Moon,
  Play,
  Plus,
  RotateCw,
  Search,
  Square,
  Sun,
  Terminal,
  TriangleAlert,
} from "lucide-react";

import {
  browse,
  fetchState,
  wakeKill,
  wakeReapAll,
  wakeStart,
  type LiveState,
  type SysStats,
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
type Col = { loading?: boolean; dirs?: string[]; error?: string };

// 收掉后压制这条会话的宽限期：只在这段时间里挡住在途旧帧把它复活（防闪回）。≈ kill 请求超时(20s)。
// 过了还在服务端帧里出现 = 这次收掉没成（进程没死），就放它回来，别让一个活会话永久隐身、没法再收。
const KILL_GRACE_MS = 20000;

export default function Page() {
  const [path, setPath] = useState("");
  const [all, setAll] = useState(false);
  const [cols, setCols] = useState<Record<string, Col>>({}); // 每个目录前缀的列内容（缓存）
  const [filter, setFilter] = useState("");
  const [polled, setPolled] = useState<WakeSession[]>([]);
  const [pending, setPending] = useState<Pending[]>([]);
  const [killed, setKilled] = useState<Map<string, number>>(new Map()); // id -> 收掉时刻；只压制 KILL_GRACE_MS 内，过期且服务端仍报这条=没收掉成，放它回来
  const [starting, setStarting] = useState<Set<string>>(new Set());
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [wakeErr, setWakeErr] = useState<string | null>(null);
  const [sys, setSys] = useState<SysStats | null>(null); // 机器负载
  const [copied, setCopied] = useState(false); // 复制路径反馈
  const [dark, setDark] = useState(true);

  useEffect(() => {
    // server 注入的首屏数据（window.__CW_INITIAL__）：直接拿来 seed 路径/各列/会话/负载，首帧即有
    // 内容、不再闪「加载中」（SSR 效果）。拿不到就退回客户端自取（readPath + 各列各自 fetch）。
    const init = (
      window as unknown as {
        __CW_INITIAL__?: {
          path?: string;
          cols?: Record<string, Col>;
          state?: { sessions?: WakeSession[]; stats?: SysStats | null };
        };
      }
    ).__CW_INITIAL__;
    if (init) {
      setPath(init.path ?? readPath());
      if (init.cols) setCols(init.cols);
      if (init.state) {
        setPolled(init.state.sessions ?? []);
        if (init.state.stats) setSys(init.state.stats);
      }
    } else {
      setPath(readPath());
    }
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

  // ---- Finder 列视图的数据层：path 是"最深选中"，每个前缀一列，缺哪列拉哪列（缓存） ----
  const segs = useMemo(() => (path ? path.split("/") : []), [path]);
  const colPrefixes = useMemo(() => {
    const out: string[] = [];
    for (let k = 0; k <= segs.length; k++) out.push(segs.slice(0, k).join("/"));
    return out; // ["", "Developer", "Developer/github", ...] —— 比 segs 多一列（最深目录的内容）
  }, [segs]);

  const colsRef = useRef(cols);
  colsRef.current = cols; // 给下面 effect 读最新缓存，又不进依赖造成循环
  const inflight = useRef<Set<string>>(new Set());
  const scrollRef = useRef<HTMLDivElement>(null);

  const fetchCol = useCallback((prefix: string, showAll: boolean) => {
    if (inflight.current.has(prefix)) return;
    inflight.current.add(prefix);
    setCols((c) => ({ ...c, [prefix]: { ...c[prefix], loading: true } }));
    browse(prefix, showAll)
      .then((d) => setCols((c) => ({ ...c, [prefix]: { dirs: d.dirs } })))
      .catch((e) => setCols((c) => ({ ...c, [prefix]: { error: String(e?.message || e) } })))
      .finally(() => inflight.current.delete(prefix));
  }, []);

  // 拉缺失的列：深链接挂载会并行拉多列；逐层导航只新增最深一列（其余命中缓存）。
  useEffect(() => {
    colPrefixes.forEach((p) => {
      const cur = colsRef.current[p];
      if (!cur || (cur.dirs === undefined && cur.error === undefined && !cur.loading)) {
        fetchCol(p, all);
      }
    });
  }, [colPrefixes, all, fetchCol]);

  // 深入时把列容器横向滚到最右，露出新开的列。
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollLeft = el.scrollWidth;
  }, [colPrefixes.length]);

  const reload = useCallback(() => {
    inflight.current.clear();
    // 直接重拉当前各列：只清缓存不行——拉列的 effect 只依赖 colPrefixes/all，
    // 清 cols 不改这俩，effect 不会重跑，列就空着不再回填（刷新「没反应」的真因）。
    colPrefixes.forEach((p) => fetchCol(p, all));
  }, [colPrefixes, all, fetchCol]);
  const toggleAll = useCallback(() => {
    inflight.current.clear();
    setCols({}); // 显示/隐藏点目录变了，各列内容都变，清缓存重拉
    setAll((v) => !v);
  }, []);

  // 把一帧组合状态 {sessions,stats} 落到 UI；并撤掉已被服务端确认的乐观占位。
  const applyState = useCallback((st: LiveState) => {
    const ss = st.sessions ?? [];
    // 墓碑维护：收掉请求在途时，之前已发出的 SSE/poll 帧可能还带着这条会话，直接落帧会把它复活
    // （消失→闪回→再消失）。两种情况撤掉墓碑：①服务端帧里不再有它（真没了，收掉成功）；
    // ②超过宽限期（收掉没成、进程没死，别让它永久隐身——放回来让用户能看到并重试）。
    setKilled((k) => {
      if (k.size === 0) return k;
      const now = Date.now();
      const next = new Map(
        [...k].filter(([id, t]) => ss.some((y) => y.id === id) && now - t < KILL_GRACE_MS),
      );
      return next.size === k.size ? k : next;
    });
    setPolled(ss);
    if (st.stats) setSys(st.stats);
    setPending((p) => p.filter((x) => !ss.some((y) => y.id === x.id)));
  }, []);
  const refreshOnce = useCallback(async () => {
    try {
      applyState(await fetchState());
    } catch {
      /* 抖动忽略 */
    }
  }, [applyState]);

  // 实时状态：主走 SSE（/api/stream，变了才推、共享 poller，省往返又防雪崩）；连不上 / 6s 没
  // 收到消息（多半是代理不透传 SSE）则自动退回轮询 /api/state。EventSource 自带断线重连。
  useEffect(() => {
    let stop = false;
    let es: EventSource | null = null;
    let pollTimer: ReturnType<typeof setTimeout>;
    let watchdog: ReturnType<typeof setTimeout>;
    const poll = () => {
      const loop = async () => {
        if (stop) return;
        await refreshOnce();
        if (!stop) pollTimer = setTimeout(loop, 1500);
      };
      loop();
    };
    const sse = () => {
      try {
        es = new EventSource("/api/stream");
      } catch {
        poll();
        return;
      }
      let got = false;
      watchdog = setTimeout(() => {
        if (!got && !stop) {
          es?.close();
          es = null;
          poll();
        }
      }, 6000);
      es.onmessage = (e) => {
        got = true;
        clearTimeout(watchdog);
        try {
          applyState(JSON.parse(e.data));
        } catch {
          /* 忽略坏帧 */
        }
      };
      es.onerror = () => {
        if (es && es.readyState === EventSource.CLOSED && !stop) {
          clearTimeout(watchdog);
          es = null;
          poll();
        }
      };
    };
    sse();
    return () => {
      stop = true;
      es?.close();
      clearTimeout(pollTimer);
      clearTimeout(watchdog);
    };
  }, [applyState, refreshOnce]);

  const navigate = useCallback((p: string) => {
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
        refreshOnce();
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
    [refreshOnce],
  );

  const doKill = useCallback(
    async (id: string) => {
      setKilled((k) => new Map(k).set(id, Date.now()));
      setPending((p) => p.filter((x) => x.id !== id));
      setPolled((p) => p.filter((x) => x.id !== id));
      try {
        await wakeKill(id);
      } catch {
        /* 尽力而为 */
      }
      refreshOnce();
    },
    [refreshOnce],
  );

  const doKillAll = useCallback(async () => {
    setKilled((k) => {
      const n = new Map(k);
      const t = Date.now();
      for (const s of polled) n.set(s.id, t);
      for (const p of pending) n.set(p.id, t);
      return n;
    });
    setPending([]);
    setPolled([]);
    try {
      await wakeReapAll();
    } catch {
      /* 尽力而为 */
    }
    refreshOnce();
  }, [refreshOnce, polled, pending]);

  const toggleTheme = () => {
    const d = !dark;
    setDark(d);
    document.documentElement.classList.toggle("dark", d);
    localStorage.setItem("cw-theme", d ? "dark" : "light");
  };

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
    return [...map.values()]
      .filter((s) => !killed.has(s.id)) // 墓碑里的（刚收掉、服务端帧还没追上）不显示
      .sort((a, b) => (a.elapsed ?? 1e9) - (b.elapsed ?? 1e9));
  }, [pending, polled, killed]);

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

  const here = path; // 当前聚焦目录 = 最深选中；在此唤醒 / 路径显示都用它
  const f = filter.trim().toLowerCase();
  // 完整绝对路径（root 来自 server；拿不到就退回 ~ 形式，照样可粘贴进 shell）
  const fullPath = path ? `${sys?.root ?? "~"}/${path}` : (sys?.root ?? "~");
  const copyPath = useCallback(() => {
    navigator.clipboard
      ?.writeText(fullPath)
      .then(() => {
        setCopied(true);
        setTimeout(() => setCopied(false), 1200);
      })
      .catch(() => {});
  }, [fullPath]);

  // 移动端的抽屉式目录树：竖向逐层展开，免左右滑。点行展开/收起（=选中该目录 / 回上一级），
  // 点 ▶ 在该目录唤醒。复用列视图同一套 cols 缓存与 path 链——展开某目录即 navigate 到它，
  // 拉它子项的活照旧交给既有 effect（colPrefixes 变了就拉），所以这里只管按缓存递归渲染。
  const renderTree = (prefix: string, depth: number): ReactNode => {
    const col = cols[prefix];
    const pad = { paddingLeft: depth * 16 + 10 };
    if (!col || (col.dirs === undefined && !col.error)) {
      return (
        <div className="text-muted-foreground flex items-center gap-2 py-2 text-sm" style={pad}>
          <Loader2 className="size-4 animate-spin" /> 加载中…
        </div>
      );
    }
    if (col.error) {
      return (
        <div className="text-destructive flex flex-col items-start gap-2 py-2 text-xs" style={pad}>
          <span className="break-words">{col.error}</span>
          <Button variant="outline" size="sm" onClick={() => fetchCol(prefix, all)}>
            <RotateCw /> 重试
          </Button>
        </div>
      );
    }
    const items = (col.dirs ?? []).filter((n) => !f || n.toLowerCase().includes(f));
    if (items.length === 0) {
      return (
        <p className="text-muted-foreground py-2 text-xs" style={pad}>
          （空）
        </p>
      );
    }
    return items.map((name) => {
      const childPath = prefix ? `${prefix}/${name}` : name;
      const open = path === childPath || path.startsWith(childPath + "/");
      const busy = starting.has(childPath);
      return (
        <div key={childPath}>
          <div
            className={cn(
              "flex items-center",
              open ? "bg-accent text-accent-foreground" : "active:bg-muted/60",
            )}
          >
            <button
              onClick={() => navigate(open ? prefix : childPath)}
              className="flex min-w-0 flex-1 items-center gap-2 py-2.5 pr-2 text-left text-sm"
              style={pad}
            >
              <ChevronRight
                className={cn(
                  "text-muted-foreground/60 size-4 shrink-0 transition-transform",
                  open && "rotate-90",
                )}
              />
              <Folder className="text-muted-foreground size-4 shrink-0" />
              <span className="truncate">{name}</span>
            </button>
            <Button
              variant="ghost"
              size="icon"
              className="mr-1 size-8 shrink-0"
              disabled={busy}
              title={`在 ${name} 唤醒`}
              onClick={() => doWake(childPath, childPath)}
            >
              {busy ? <Loader2 className="animate-spin" /> : <Play />}
            </Button>
          </div>
          {open && renderTree(childPath, depth + 1)}
        </div>
      );
    });
  };

  return (
    <div className="min-h-screen">
      <header className="flex items-center justify-between gap-3 px-5 pt-6 pb-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">🛟 claude-wake</h1>
          <p className="text-muted-foreground text-sm">选个目录，远程起一个 claude 会话</p>
        </div>
        <div className="flex items-center gap-2">
          {sys && <StatBar sys={sys} />}
          <Button variant="ghost" size="icon" onClick={toggleTheme} title="切换主题">
            {dark ? <Sun /> : <Moon />}
          </Button>
        </div>
      </header>

      {sys?.busy && (
        <div className="mx-5 mb-3 flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-600 dark:text-amber-400">
          <TriangleAlert className="mt-0.5 size-4 shrink-0" />
          <span>
            机器负载偏高（每核 {sys.loadPerCpu}、内存 {sys.memUsedPct}%
            {sys.swapUsedMB > 1024 && ` 、swap ${(sys.swapUsedMB / 1024).toFixed(1)}G`}）。
            每个 claude 会话是个重 Node 进程，现在唤醒可能很慢甚至超时——建议先收掉些会话或等负载降下来再起。
          </span>
        </div>
      )}

      {wakeErr && (
        <div className="border-destructive/40 text-destructive mx-5 mb-3 rounded-lg border px-4 py-3 text-sm">
          唤醒失败：{wakeErr}
        </div>
      )}

      {/* App shell：会话独立成左侧全高栏（不再和文件浏览器挤同一居中块），主区吃满剩余宽度 */}
      <div className="md:flex md:items-stretch">
        {/* 左栏：会话；移动端为顶部块，桌面端为左侧全高栏 */}
        {(sessions.length > 0 || starting.size > 0) && (
          <aside className="flex flex-col gap-2 px-5 pb-6 md:w-72 md:shrink-0 md:border-r md:px-4 md:py-4">
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
                    {starting.has("+" + g.dir) ? <Loader2 className="animate-spin" /> : <Plus />}
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

        {/* 主区：Finder 列视图，吃满剩余宽度 */}
        <main className="min-w-0 px-5 pb-10 md:flex-1 md:px-6 md:py-4">
          {/* 顶栏只放操作：导航靠点列 + 底部路径栏，不再要「上级」 */}
          <div className="mb-3 flex flex-wrap items-center gap-2">
            <Button variant="outline" size="sm" onClick={reload} title="刷新">
              <RotateCw />
            </Button>
            <Button variant="outline" size="sm" onClick={toggleAll}>
              {all ? <EyeOff /> : <Eye />}
              {all ? "隐藏点目录" : "显示隐藏"}
            </Button>
            <div className="relative min-w-0 flex-1">
              <Search className="text-muted-foreground absolute top-1/2 left-3 size-4 -translate-y-1/2" />
              <input
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="过滤各列…"
                className="border-input bg-background focus-visible:ring-ring/50 h-9 w-full rounded-md border pr-3 pl-9 text-sm outline-none focus-visible:ring-[3px]"
              />
            </div>
            {/* 桌面端靠悬停某目录点 ▶ 唤醒，这按钮多余；只在移动端（无悬停、点不出 ▶）留一个唤醒当前目录的入口 */}
            <Button
              size="sm"
              className="md:hidden"
              disabled={starting.has(".")}
              onClick={() => doWake(here, ".")}
            >
              {starting.has(".") ? <Loader2 className="animate-spin" /> : <Play />}
              在此唤醒
            </Button>
          </div>

          {/* 移动端：抽屉式目录树（竖向逐层展开，免左右滑）。桌面切回下面的 Finder 列视图 */}
          <div className="cw-scroll bg-card h-[62vh] overflow-y-auto rounded-lg border md:hidden">
            {renderTree("", 0)}
          </div>

          {/* Finder 列视图（Miller columns）：每层一列，点文件夹右侧开新列；▶ 悬停在该目录唤醒。仅桌面 */}
          <div
            ref={scrollRef}
            className="cw-scroll bg-card hidden h-[62vh] overflow-x-auto rounded-lg border md:flex"
          >
            {colPrefixes.map((prefix, k) => {
              const selected = segs[k]; // 本列里高亮的子目录（指向下一列）；最后一列无
              const col = cols[prefix];
              const items = (col?.dirs ?? []).filter((n) => !f || n.toLowerCase().includes(f));
              return (
                // 固定容器高度 + flex 默认 align-stretch → 每列撑满全高；显式 border-r（不靠 divide-x，
                // 它在这套 Tailwind v4 配置下没渲染出竖线）让列间分割线整条到底，短内容也有线。
                <div
                  key={prefix || "~"}
                  className={cn(
                    "cw-scroll w-56 shrink-0 overflow-y-auto",
                    k < colPrefixes.length - 1 && "col-divider",
                  )}
                >
                  {col?.error ? (
                    <div className="text-destructive flex flex-col items-start gap-2 p-3 text-xs">
                      <span className="break-words">{col.error}</span>
                      <Button variant="outline" size="sm" onClick={() => fetchCol(prefix, all)}>
                        <RotateCw /> 重试
                      </Button>
                    </div>
                  ) : col?.dirs === undefined ? (
                    // 只在【主动 fetch 中】转圈；未取过（首屏静态 HTML / 注入前）留白，不闪 spinner
                    col?.loading ? (
                      <div className="text-muted-foreground flex items-center gap-2 p-3 text-sm">
                        <Loader2 className="size-4 animate-spin" /> 加载中…
                      </div>
                    ) : null
                  ) : items.length === 0 ? (
                    <p className="text-muted-foreground p-3 text-xs">（空）</p>
                  ) : (
                    items.map((name) => {
                      const childPath = prefix ? `${prefix}/${name}` : name;
                      const isSel = name === selected;
                      const busy = starting.has(childPath);
                      return (
                        <div
                          key={name}
                          className={cn(
                            "group flex items-center pr-1",
                            isSel
                              ? "bg-accent text-accent-foreground"
                              : "hover:bg-muted/60",
                          )}
                        >
                          <button
                            onClick={() => navigate(childPath)}
                            className="flex min-w-0 flex-1 items-center gap-2 px-2.5 py-1.5 text-left text-sm"
                          >
                            <Folder className="text-muted-foreground size-4 shrink-0" />
                            <span className="truncate">{name}</span>
                          </button>
                          <Button
                            variant="ghost"
                            size="icon"
                            className="hidden size-6 shrink-0 group-hover:flex"
                            disabled={busy}
                            title={`在 ${name} 唤醒`}
                            onClick={() => doWake(childPath, childPath)}
                          >
                            {busy ? <Loader2 className="animate-spin" /> : <Play />}
                          </Button>
                          <ChevronRight className="text-muted-foreground/40 size-3.5 shrink-0 group-hover:hidden" />
                        </div>
                      );
                    })
                  )}
                </div>
              );
            })}
          </div>

          {/* 底部路径栏（Finder 式）：左侧面包屑任意段可点跳转，右侧一键复制完整绝对路径 */}
          <div className="mt-2 flex items-stretch gap-2">
            <nav className="cw-scroll bg-muted/40 text-muted-foreground flex min-w-0 flex-1 items-center gap-1 overflow-x-auto rounded-md border px-2.5 py-1.5 text-xs whitespace-nowrap">
              <Folder className="size-3.5 shrink-0" />
              <button onClick={() => navigate("")} className="hover:text-foreground shrink-0">
                ~
              </button>
              {segs.map((seg, i) => {
                const target = segs.slice(0, i + 1).join("/");
                const last = i === segs.length - 1;
                return (
                  <span key={target} className="flex shrink-0 items-center gap-1">
                    <ChevronRight className="size-3 shrink-0 opacity-40" />
                    {last ? (
                      <span className="text-foreground font-medium">{seg}</span>
                    ) : (
                      <button onClick={() => navigate(target)} className="hover:text-foreground">
                        {seg}
                      </button>
                    )}
                  </span>
                );
              })}
            </nav>
            <Button
              variant="outline"
              size="sm"
              className="shrink-0"
              onClick={copyPath}
              title={`复制完整路径：${fullPath}`}
            >
              {copied ? <Check className="text-green-500" /> : <Copy />}
              {copied ? "已复制" : "复制路径"}
            </Button>
          </div>
        </main>
      </div>

      <footer className="text-muted-foreground/70 mt-10 px-5 pb-6 text-center text-xs">
        限根 $HOME · 可并存多个会话 · Next 16.3 preview + shadcn ·{" "}
        <a className="underline" href="/browse">
          纯 HTML 版
        </a>
      </footer>
    </div>
  );
}

// 机器负载条：每核负载 + 内存% + swap（吃紧时变琥珀）。窄屏隐藏，靠下面的警告横幅。
function StatBar({ sys }: { sys: SysStats }) {
  return (
    <div
      className={cn(
        "hidden items-center gap-3 rounded-md border px-2.5 py-1 text-xs sm:flex",
        sys.busy
          ? "border-amber-500/40 text-amber-600 dark:text-amber-400"
          : "text-muted-foreground border-transparent",
      )}
    >
      <span className="flex items-center gap-1" title={`load ${sys.load1} · ${sys.ncpu} 核`}>
        <Cpu className="size-3.5" /> {sys.loadPerCpu}×
      </span>
      <span className="flex items-center gap-1" title={`${sys.memUsedMB} / ${sys.memTotalMB} MB`}>
        <MemoryStick className="size-3.5" /> {sys.memUsedPct}%
      </span>
      {sys.swapUsedMB > 1024 && (
        <span title="swap 使用">swap {(sys.swapUsedMB / 1024).toFixed(1)}G</span>
      )}
    </div>
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

          {s.phase === "failed" ? (
            <p className="text-destructive text-xs">
              RC 注册失败：claude 起来了但云连接被拒（多为 keychain 登录态失效，需本机重登一次）。
            </p>
          ) : s.phase !== "ready" ? (
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
          ) : null}

          {/* 操作一行：就绪了就把「接管」和「收掉」并排（URL 不再单独列一行，点接管即打开） */}
          <div className="flex gap-2">
            {s.phase === "ready" && s.url && (
              <Button size="sm" className="flex-1" onClick={() => window.open(s.url!, "_blank")}>
                <ExternalLink /> 接管
              </Button>
            )}
            <Button
              variant="destructive"
              size="sm"
              className={cn(s.phase === "ready" && s.url ? "shrink-0" : "self-start")}
              onClick={onKill}
            >
              <Square /> 收掉
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
