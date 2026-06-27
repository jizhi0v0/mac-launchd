import type { NextConfig } from "next";

// 静态导出（output: export）→ 纯 SPA，由 claude-wake 的 Python daemon 托管在 /app 下。
// 数据都走同源 /api/*（Python 提供、Cookie 鉴权），所以不需要任何 server 运行时。
const nextConfig: NextConfig = {
  output: "export",
  basePath: "/app",
  trailingSlash: true,
  images: { unoptimized: true },
};

export default nextConfig;
