// astro.config.mjs
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import sitemap from "@astrojs/sitemap";
import { loadEnv } from "vite";
import { scanBlogContent } from "./scripts/lib/content-meta.mjs";

const env = loadEnv(process.env.NODE_ENV ?? "production", process.cwd(), "");

const isBuild = process.argv.includes("build");
const site =
  process.env.SITE_URL ??
  env.SITE_URL ??
  (isBuild ? undefined : "http://localhost:4321");

if (!site) {
  throw new Error("SITE_URL is required during build.");
}

// draft 页面不会生成路由；noindex 页面会生成但必须排除出 Sitemap。
// 这里在构建期扫描 Frontmatter，得到需要排除的路径集合。
const excludedFromSitemap = new Set(
  scanBlogContent()
    .filter((entry) => entry.data.draft || entry.data.noindex)
    .map((entry) => entry.path),
);

export default defineConfig({
  site,
  output: "static",
  trailingSlash: "always",
  integrations: [
    mdx(),
    sitemap({
      filter: (page) => {
        const path = new URL(page).pathname;
        if (path === "/404/" || path === "/404.html") return false;
        return !excludedFromSitemap.has(path);
      },
    }),
  ],
  i18n: {
    locales: ["en", "ar", "pl", "zh"],
    defaultLocale: "en",
    routing: {
      prefixDefaultLocale: false,
    },
  },
});
