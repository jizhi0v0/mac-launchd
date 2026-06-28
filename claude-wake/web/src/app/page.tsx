"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CheckCircle2,
  ChevronUp,
  Circle,
  ExternalLink,
  Eye,
  EyeOff,
  Folder,
  Loader2,
  Moon,
  Play,
  RotateCw,
  Search,
  Square,
  Sun,
  Terminal,
  TriangleAlert,
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
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

function readPath() {
  if (typeof window === "undefined") return "";
  return new URLSearchParams(window.location.search).get("p") || "";
}

const basename = (p: string) => p.replace(/\/+$/, "").split("/").pop() || p || "~";

// 进度链路（每个会话独立走）：起会话即完成 step0；booting→step1 在跑，rendering→step3(注册 RC)
// 在跑，ready→全完成。
const STEPS = ["起 claude", "冷启动 · 等 TUI", "TUI 渲染", "注册 RC 云连接", "拿到接管链接"];
function activeStep(phase: WakeSession["phase"]): number {
  if (phase === "ready") return STEPS.length;
  if (phase === "rendering") return 3;
  return 1; // booting
}

// 乐观占位：start 成功后立刻塞一个，等轮询把真实状态接上（按 id 对齐）。
type Pending = { id: string; rc: string; dir: string; started: number };

export default function Page() {
  const [path, setPath] = useState("");
  const [all, setAll] = useState(false);
  const [data, setData] = useState<BrowseData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [polled, setPolled] = useState<WakeSession[]>([]); // 轮询到的 live 会话
  const [pending, setPending] = useState<Pending[]>([]); // 刚起、轮询还没接上的占位
  const [starting, setStarting] = useState<Set<string>>(new Set()); // 正在发起的按钮 key
  const [wakeErr, setWakeErr] = useState<string | null>(null);
  const [dark, setDark] = useState(true);
  const loadSeq = useRef(0); // 只让最新一次 browse 落地（见下方注释）

  // 初始：URL 里的 p= + localStorage 主题；监听浏览器前进/后退
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
    // 抢占式序号：深链接挂载会同时发"根"和"深"两个 browse，谁后返回谁覆盖 data。只认最新一次，
    // 否则会出现 data=根列表、path=深路径的错配，点进去会把根文件夹拼到深 path 后面（bad path）。
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

  // 会话轮询：无超时，一直 loop 抓所有 live 会话的状态（冷启动→注册→就绪）。单次失败不清空列表。
  const refreshSessions = useCallback(async () => {
    try {
      const s = await wakeSessions();
      setPolled(s);
      setPending((p) => p.filter((x) => !s.some((y) => y.id === x.id))); // 轮询接上了就撤占位
    } catch {
      /* 网络抖动：保留上次列表，下个 tick 再试 */
    }
  }, []);
  useEffect(() => {
    refreshSessions();
    const iv = setInterval(refreshSessions, 1500);
    return () => clearInterval(iv);
  }, [refreshSessions]);

  const navigate = useCallback((p: string) => {
    setFilter("");
    // 保留 token query：跳转后的 URL 仍自带鉴权，刷新/分享/书签都不掉 token。
    const params = new URLSearchParams();
    if (p) params.set("p", p);
    const token = new URLSearchParams(window.location.search).get("token");
    if (token) params.set("token", token);
    const qs = params.toString();
    window.history.pushState({ p }, "", qs ? `?${qs}` : window.location.pathname);
    setPath(p);
  }, []);

  // 唤醒：起一个独立会话；不阻塞、不影响其它。起好后乐观占位，轮询接上真实进度。
  const doWake = useCallback(
    async (p: string, key: string) => {
      setWakeErr(null);
      setStarting((s) => new Set(s).add(key));
      try {
        const r = await wakeStart(p);
        setPending((prev) => [
          { id: r.job, rc: r.rc, dir: r.dir, started: Date.now() },
          ...prev,
        ]);
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
      setPending((p) => p.filter((x) => x.id !== id)); // 乐观移除
      setPolled((p) => p.filter((x) => x.id !== id));
      try {
        await wakeKill(id);
      } catch {
        /* 收掉尽力而为 */
      }
      refreshSessions();
    },
    [refreshSessions],
  );

  const doKillAll = useCallback(async () => {
    setPending([]); // 乐观清空
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

  // 合并占位 + 轮询结果（按 id 去重，轮询为准），新的（elapsed 小）排上面。
  const sessions = useMemo(() => {
    const map = new Map<string, WakeSession>();
    for (const p of pending)
      map.set(p.id, {
        id: p.id,
        rc: p.rc,
        dir: p.dir,
        phase: "booting",
        elapsed: Math.floor((Date.now() - p.started) / 1000),
        url: null,
        tail: [],
      });
    for (const s of polled) map.set(s.id, s);
    return [...map.values()].sort(
      (a, b) => (a.elapsed ?? 1e9) - (b.elapsed ?? 1e9),
    );
  }, [pending, polled]);

  // 子目录路径基于 data.rel（当前【真正展示】的列表所属路径），不用 path（可能是还在加载的目标）。
  const here = data?.rel ?? "";
  const child = (name: string) => (here ? `${here}/${name}` : name);

  return (
    <main className="mx-auto w-full max-w-4xl px-4 py-6 sm:py-10">
      <header className="mb-6 flex items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">🛟 claude-wake</h1>
          <p className="text-muted-foreground text-sm">选个目录，远程起一个 claude 会话</p>
        </div>
        <Button variant="ghost" size="icon" onClick={toggleTheme} title="切换主题">
          {dark ? <Sun /> : <Moon />}
        </Button>
      </header>

      {/* live 会话列表：每个独立，各自看进度、各自收掉。无超时，一直轮询。 */}
      {sessions.length > 0 && (
        <section className="mb-6 flex flex-col gap-3">
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
              进行中的会话 · {sessions.length}
            </h2>
            {sessions.length > 1 && (
              <Button variant="ghost" size="sm" onClick={doKillAll}>
                <Square /> 全部收掉
              </Button>
            )}
          </div>
          {sessions.map((s) => (
            <SessionCard key={s.id} s={s} onKill={() => doKill(s.id)} />
          ))}
        </section>
      )}

      {wakeErr && (
        <div className="border-destructive/40 text-destructive mb-5 rounded-lg border px-4 py-3 text-sm">
          唤醒失败：{wakeErr}
        </div>
      )}

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          disabled={!data || data.atRoot || loading}
          onClick={() => data?.parent != null && navigate(data.parent)}
        >
          <ChevronUp /> 上级
        </Button>
        {/* 面包屑：每一层都可点，快速跳到任意上级；最后一段是当前目录、不可点 */}
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
            "grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3",
            // loading 时把旧列表压暗并禁止点击——否则跳转途中还能点别的文件夹，造成竞态
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

      <footer className="text-muted-foreground/70 mt-10 text-center text-xs">
        限根 $HOME · 可并存多个会话 · Next 16.3 preview + shadcn ·{" "}
        <a className="underline" href="/browse">
          纯 HTML 版
        </a>
      </footer>
    </main>
  );
}

// 单个会话卡片：就绪→给接管链接；进行中→走详细链路 + 终端尾巴；失败→报错。永远有「收掉」。
function SessionCard({ s, onKill }: { s: WakeSession; onKill: () => void }) {
  const ai = activeStep(s.phase);
  const slow = s.phase === "booting" && (s.elapsed ?? 0) >= 15;
  return (
    <Card className={cn(s.phase === "failed" ? "border-destructive/40" : "border-primary/40")}>
      <CardHeader>
        <CardTitle className="flex items-center justify-between gap-2">
          <span className="flex min-w-0 items-center gap-2">
            {s.phase === "ready" ? (
              <CheckCircle2 className="text-primary size-4 shrink-0" />
            ) : s.phase === "failed" ? (
              <TriangleAlert className="text-destructive size-4 shrink-0" />
            ) : (
              <Loader2 className="text-primary size-4 shrink-0 animate-spin" />
            )}
            <span className="truncate">{basename(s.dir)}</span>
            {s.elapsed != null && (
              <span className="text-muted-foreground text-xs font-normal">{s.elapsed}s</span>
            )}
          </span>
          <Button variant="destructive" size="sm" onClick={onKill}>
            <Square /> 收掉
          </Button>
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <p className="text-muted-foreground font-mono text-[11px] break-all">{s.rc}</p>

        {s.phase === "ready" && s.url ? (
          <>
            <a
              href={s.url}
              target="_blank"
              rel="noreferrer"
              className="text-muted-foreground hover:text-foreground font-mono text-xs break-all underline"
            >
              {s.url}
            </a>
            <Button onClick={() => window.open(s.url!, "_blank")}>
              <ExternalLink /> 在 Claude 接管
            </Button>
          </>
        ) : s.phase === "failed" ? (
          <p className="text-destructive text-sm">
            RC 注册失败：claude 起来了但云连接被拒（多为 keychain 登录态失效，需本机重登一次）。
          </p>
        ) : (
          <>
            <ol className="flex flex-col gap-1.5 text-sm">
              {STEPS.map((label, i) => {
                const done = i < ai;
                const running = i === ai;
                return (
                  <li
                    key={label}
                    className={cn(
                      "flex items-center gap-2",
                      done && "text-foreground",
                      running && "text-foreground font-medium",
                      !done && !running && "text-muted-foreground/50",
                    )}
                  >
                    {done ? (
                      <CheckCircle2 className="text-primary size-4 shrink-0" />
                    ) : running ? (
                      <Loader2 className="text-primary size-4 shrink-0 animate-spin" />
                    ) : (
                      <Circle className="size-4 shrink-0" />
                    )}
                    {label}
                    {running && i === 1 && slow && (
                      <span className="text-muted-foreground text-xs">（偏久，可「收掉」重试）</span>
                    )}
                  </li>
                );
              })}
            </ol>
            {s.tail.length > 0 && (
              <pre className="bg-muted/60 text-muted-foreground max-h-44 overflow-auto rounded-md p-2.5 font-mono text-[11px] leading-relaxed">
                <span className="text-muted-foreground/60 mb-1 flex items-center gap-1.5">
                  <Terminal className="size-3" /> 终端
                </span>
                {s.tail.join("\n")}
              </pre>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}
