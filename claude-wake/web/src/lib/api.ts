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

export async function browse(path: string, all: boolean): Promise<BrowseData> {
  const u = new URL("/api/browse", location.origin);
  if (path) u.searchParams.set("path", path);
  if (all) u.searchParams.set("all", "1");
  return jsonOrThrow(await fetch(u, { credentials: "same-origin" }), "浏览");
}

// 在某相对路径目录起会话；返回 claude.ai/code 接管链接。path 为 "" → 根（$HOME，慢，慎用）。
export async function wake(path: string): Promise<string> {
  const r = await fetch("/api/wake", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: new URLSearchParams(path ? { path } : {}),
    credentials: "same-origin",
  });
  const j = await jsonOrThrow(r, "唤醒");
  if (!j.url) throw new Error("没拿到接管链接");
  return j.url as string;
}
