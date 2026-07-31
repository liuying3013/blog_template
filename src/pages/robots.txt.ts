// src/pages/robots.txt.ts
// robots.txt 需要绝对 Sitemap 地址，因此在构建期由 SITE_URL 生成，
// 而不是放在 public/ 里写死域名。
import type { APIContext } from "astro";
import { siteConfig } from "../config/site";

export function GET(context: APIContext) {
  const site = context.site ?? new URL(siteConfig.siteUrl);
  const sitemapUrl = new URL("sitemap-index.xml", site).toString();

  const body = [
    "User-agent: *",
    "Allow: /",
    "",
    `Sitemap: ${sitemapUrl}`,
    "",
  ].join("\n");

  return new Response(body, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
    },
  });
}
