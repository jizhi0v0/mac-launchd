import type { Metadata } from "next";
import "./globals.css";

// 不用 next/font/google：静态导出会在构建期联网拉字体，本机网络（Surge）常连不上 → 卡构建。
// 用系统字体栈，零网络依赖。
export const metadata: Metadata = {
  title: "claude-wake",
  description: "远程唤醒一个 claude 会话",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh" className="dark h-full antialiased">
      <head>
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover" />
        <style>{`
          :root {
            --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
            --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          body { font-family: var(--font-sans); }
        `}</style>
      </head>
      <body className="min-h-full">{children}</body>
    </html>
  );
}
