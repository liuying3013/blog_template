// SEO 校验（构建后，检查 dist/）：
// - draft 页面不允许被渲染进 dist
// - draft / noindex 页面不允许出现在 Sitemap
// - 每个文章页必须有 Title、Meta Description、Canonical
// - Canonical 必须指向 SITE_URL 域名
// 通过 package.json 的 build 脚本在 astro build 之后自动执行。

import fs from "node:fs";
import path from "node:path";
import {
  scanBlogContent,
  loadDotEnv,
} from "./lib/content-meta.mjs";

const DIST = path.resolve("dist");

if (!fs.existsSync(DIST)) {
  console.error("❌ dist/ 不存在，请先运行 astro build");
  process.exit(1);
}

const env = { ...loadDotEnv(), ...process.env };
const siteUrl = env.SITE_URL;

if (!siteUrl) {
  console.error("❌ SITE_URL 未设置，无法校验 Canonical");
  process.exit(1);
}

const entries = scanBlogContent();
const errors = [];

// 收集 Sitemap 中的全部 URL
const sitemapUrls = new Set();
for (const file of fs.readdirSync(DIST)) {
  if (!/^sitemap.*\.xml$/.test(file)) continue;
  const xml = fs.readFileSync(path.join(DIST, file), "utf8");
  for (const match of xml.matchAll(/<loc>([^<]+)<\/loc>/g)) {
    const url = match[1];
    if (url.endsWith(".xml")) continue; // sitemap index 里的子 sitemap
    sitemapUrls.add(new URL(url).pathname);
  }
}

if (sitemapUrls.size === 0) {
  errors.push("Sitemap 为空或不存在");
}

const distFileFor = (urlPath) =>
  path.join(DIST, urlPath.replace(/^\//, ""), "index.html");

for (const entry of entries) {
  const htmlPath = distFileFor(entry.path);

  if (entry.data.draft) {
    if (fs.existsSync(htmlPath)) {
      errors.push(`${entry.file}: draft 文章被渲染进了 dist（${entry.path}）`);
    }
    if (sitemapUrls.has(entry.path)) {
      errors.push(`${entry.file}: draft 文章出现在 Sitemap（${entry.path}）`);
    }
    continue;
  }

  if (entry.data.noindex && sitemapUrls.has(entry.path)) {
    errors.push(`${entry.file}: noindex 文章出现在 Sitemap（${entry.path}）`);
  }

  if (!fs.existsSync(htmlPath)) {
    errors.push(`${entry.file}: 构建产物缺失（${entry.path}）`);
    continue;
  }

  const html = fs.readFileSync(htmlPath, "utf8");

  if (!/<title>[^<]+<\/title>/.test(html)) {
    errors.push(`${entry.path}: 缺少 <title>`);
  }
  if (!/<meta[^>]+name="description"[^>]+content="[^"]+"/.test(html)) {
    errors.push(`${entry.path}: 缺少 Meta Description`);
  }

  const canonicalMatch = html.match(
    /<link[^>]+rel="canonical"[^>]+href="([^"]+)"/,
  );
  if (!canonicalMatch) {
    errors.push(`${entry.path}: 缺少 Canonical`);
  } else if (!canonicalMatch[1].startsWith(siteUrl)) {
    errors.push(
      `${entry.path}: Canonical "${canonicalMatch[1]}" 指向错误域名（应属于 ${siteUrl}）`,
    );
  }

  if (entry.data.noindex && !/<meta[^>]+name="robots"[^>]+noindex/.test(html)) {
    errors.push(`${entry.path}: noindex 文章缺少 robots noindex 标记`);
  }

  if (!entry.data.noindex && !sitemapUrls.has(entry.path)) {
    errors.push(`${entry.path}: 可索引文章未出现在 Sitemap`);
  }
}

if (errors.length > 0) {
  console.error("❌ SEO 校验失败：");
  for (const error of errors) console.error(`   ${error}`);
  process.exit(1);
}

console.log(
  `✅ SEO 校验通过：Sitemap ${sitemapUrls.size} 个 URL，文章 ${entries.length} 篇`,
);
