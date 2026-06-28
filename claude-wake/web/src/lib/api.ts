// claude-wake 后端（Python daemon，同源）API 客户端。
// 鉴权全靠 HttpOnly Cookie：入口 /app?token=… 加载时服务端已种好，这里的 fetch 同源自动带上。
// 注意：basePath 是 /app，但这些是裸 fetch，必须用绝对路径（前导 /）打到 origin 根，不走 basePath。

export type BrowseData = {
  rel: string; // 相对 BROWSE_ROOT，根为 ""
  crumb: string; // 展示用，如 "~/Developer/github"
  parent: string | null; // 上级 rel；根为 null
  atRoot: boolean;
  dirs: string[]; // 子目录名（已按服务端规则过滤/排序）
  showHidden: boolean;
};

async function jsonOrThrow(r: Response, what: string) {
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j?.error || `${what} 失败 (${r.status})`);
  return j;
}

// 带超时的 fetch：卡住就 abort 抛错，避免 UI 无限转圈（远程链路抖动时尤其重要）。
async function fetchT(input: URL | string, init: RequestInit, ms: number) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(input, { ...init, signal: ctrl.signal });
  } catch (e) {
    if ((e as Error)?.name === "AbortError") throw new Error(`请求超时（${ms / 1000}s）`);
    throw e;
  } finally {
    clearTimeout(t);
  }
}

export async function browse(path: string, all: boolean): Promise<BrowseData> {
  const u = new URL("/api/browse", location.origin);
  if (path) u.searchParams.set("path", path);
  if (all) u.searchParams.set("all", "1");
  return jsonOrThrow(await fetchT(u, { credentials: "same-origin" }, 12000), "浏览");
}

// ---- 流式唤醒：start 立刻拿 job → 不断 poll 看详细链路 → 需要时 kill ----
// 为什么不再用一次性阻塞 /api/wake：那个闷等、有超时、卡住没法中途收。改成三件套，
// 前端能显示"冷启动→注册 RC→拿到链接"的具体进度，不存在超时，卡了可远程 kill。

export type WakePhase =
  | "booting" // pane 空白：claude 冷启动中
  | "rendering" // TUI 起来了：正注册 RC 云连接、等 URL
  | "ready" // 拿到接管链接
  | "failed"; // RC 注册失败 banner

// 一个 live 会话的实时状态（多会话：可并存任意多个）。
export type WakeSession = {
  id: string;
  rc: string;
  dir: string;
  phase: WakePhase;
  elapsed: number | null; // 起会话至今秒数；server 重启后/外部起的会话未知 → null
  url: string | null;
  tail: string[]; // 终端尾巴几行，直接显示
};

const FORM = {
  "Content-Type": "application/x-www-form-urlencoded",
  Accept: "application/json",
};

// 起一个【独立】后台会话，立刻返回 job(=会话 id)，不等 URL。可并存多个。path 为 "" → 默认 /tmp 空目录。
export async function wakeStart(
  path: string,
): Promise<{ job: string; rc: string; dir: string }> {
  const r = await fetchT(
    "/api/wake/start",
    {
      method: "POST",
      headers: FORM,
      body: new URLSearchParams(path ? { path } : {}),
      credentials: "same-origin",
    },
    30000,
  );
  return jsonOrThrow(r, "起会话");
}

// 拉取所有 live 会话的实时状态。无超时概念——卡住的会话就一直停在某 phase，由用户对它点收掉。
// 单次请求给 15s 网络超时（卡住抛错，调用方下个 tick 再试，不影响已有列表）。
export async function wakeSessions(): Promise<WakeSession[]> {
  const u = new URL("/api/wake/sessions", location.origin);
  return jsonOrThrow(await fetchT(u, { credentials: "same-origin" }, 15000), "查会话");
}

// 精准收掉【某一个】会话（本地进程 + 注销云端登记），不动其它并存会话。
export async function wakeKill(job: string): Promise<void> {
  await fetchT(
    "/api/wake/kill",
    {
      method: "POST",
      headers: FORM,
      body: new URLSearchParams({ job }),
      credentials: "same-origin",
    },
    20000,
  );
}

// 一键收掉所有 live 会话。
export async function wakeReapAll(): Promise<void> {
  await fetchT(
    "/api/wake/reap-all",
    { method: "POST", headers: FORM, credentials: "same-origin" },
    30000,
  );
}
