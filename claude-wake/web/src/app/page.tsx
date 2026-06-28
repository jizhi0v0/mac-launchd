"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ChevronUp,
  ExternalLink,
  Eye,
  EyeOff,
  Folder,
  Loader2,
  Moon,
  Play,
  RotateCw,
  Search,
  Sun,
  X,
} from "lucide-react";

import { browse, wake, type BrowseData } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

function readPath() {
  if (typeof window === "undefined") return "";
  return new URLSearchParams(window.location.search).get("p") || "";
}

export default function Page() {
  const [path, setPath] = useState("");
  const [all, setAll] = useState(false);
  const [data, setData] = useState<BrowseData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [waking, setWaking] = useState<string | null>(null);
  const [wakeUrl, setWakeUrl] = useState<string | null>(null);
  const [wakeErr, setWakeErr] = useState<string | null>(null);
  const [dark, setDark] = useState(true);

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
    setLoading(true);
    setError(null);
    browse(p, showAll)
      .then(setData)
      .catch((e) => setError(String(e?.message || e)))
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    load(path, all);
  }, [path, all, load]);

  const navigate = useCallback((p: string) => {
    setFilter("");
    // 保留 token query：跳转后的 URL 仍自带鉴权，刷新/分享/书签都不掉 token。
    // （同会话其实靠 Cookie 也能认，但裸开跳转后的 URL 没 Cookie 会 401，所以带上更稳。）
    const params = new URLSearchParams();
    if (p) params.set("p", p);
    const token = new URLSearchParams(window.location.search).get("token");
    if (token) params.set("token", token);
    const qs = params.toString();
    window.history.pushState({ p }, "", qs ? `?${qs}` : window.location.pathname);
    setPath(p);
  }, []);

  const doWake = useCallback(async (p: string, key: string) => {
    setWaking(key);
    setWakeErr(null);
    setWakeUrl(null);
    try {
      setWakeUrl(await wake(p));
    } catch (e) {
      setWakeErr(String((e as Error)?.message || e));
    } finally {
      setWaking(null);
    }
  }, []);

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

  const child = (name: string) => (path ? `${path}/${name}` : name);

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

      {wakeUrl && (
        <Card className="border-primary/40 mb-5">
          <CardHeader>
            <CardTitle className="flex items-center justify-between">
              <span>✅ 会话已就绪</span>
              <Button variant="ghost" size="icon" onClick={() => setWakeUrl(null)}>
                <X />
              </Button>
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-3">
            <a
              href={wakeUrl}
              target="_blank"
              rel="noreferrer"
              className="text-muted-foreground hover:text-foreground font-mono text-xs break-all underline"
            >
              {wakeUrl}
            </a>
            <Button onClick={() => window.open(wakeUrl, "_blank")}>
              <ExternalLink /> 在 Claude 接管
            </Button>
          </CardContent>
        </Card>
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
          disabled={!data || data.atRoot}
          onClick={() => data?.parent != null && navigate(data.parent)}
        >
          <ChevronUp /> 上级
        </Button>
        <code className="bg-muted text-muted-foreground min-w-0 flex-1 truncate rounded-md px-2.5 py-1.5 text-xs">
          {data?.crumb ?? "~"}
        </code>
        <Button variant="outline" size="sm" onClick={() => load(path, all)} title="刷新">
          <RotateCw className={cn(loading && "animate-spin")} />
        </Button>
        <Button variant="outline" size="sm" onClick={() => setAll((v) => !v)}>
          {all ? <EyeOff /> : <Eye />}
          {all ? "隐藏点目录" : "显示隐藏"}
        </Button>
        <Button size="sm" disabled={waking !== null} onClick={() => doWake(path, ".")}>
          {waking === "." ? <Loader2 className="animate-spin" /> : <Play />}
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
        <div className="border-destructive/40 text-destructive rounded-lg border px-4 py-3 text-sm">
          {error}
        </div>
      ) : loading && !data ? (
        <div className="text-muted-foreground flex items-center gap-2 px-1 py-8 text-sm">
          <Loader2 className="animate-spin" /> 加载中…
        </div>
      ) : dirs.length === 0 ? (
        <p className="text-muted-foreground px-1 py-8 text-sm">（无子目录）</p>
      ) : (
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {dirs.map((name) => {
            const cp = child(name);
            const busy = waking === cp;
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
                  disabled={waking !== null}
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
        限根 $HOME · Next 16.3 preview + shadcn ·{" "}
        <a className="underline" href="/browse">
          纯 HTML 版
        </a>
      </footer>
    </main>
  );
}
