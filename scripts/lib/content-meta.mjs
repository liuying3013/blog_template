// Node 侧内容扫描：astro.config.mjs 和校验脚本共用。
// 只读 Frontmatter，不做渲染。

import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import {
  LOCALES,
  blogUrlPath,
} from "../../src/lib/paths.mjs";

const CONTENT_DIR = path.resolve("src/content/blog");

/**
 * 读取 .env（存在时），返回键值对象；不覆盖已有的 process.env。
 */
export function loadDotEnv() {
  const envPath = path.resolve(".env");
  const values = {};

  if (!fs.existsSync(envPath)) return values;

  for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;

    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    values[key] = value;
  }

  return values;
}

/**
 * @returns {Array<{file: string, locale: string, slug: string, path: string, data: any, body: string}>}
 */
export function scanBlogContent() {
  if (!fs.existsSync(CONTENT_DIR)) return [];

  const entries = [];

  for (const locale of LOCALES) {
    const dir = path.join(CONTENT_DIR, locale);
    if (!fs.existsSync(dir)) continue;

    for (const file of fs.readdirSync(dir).sort()) {
      if (!/\.(md|mdx)$/.test(file)) continue;

      const fullPath = path.join(dir, file);
      const { data, content } = matter(
        fs.readFileSync(fullPath, "utf8"),
      );
      const slug = file.replace(/\.(md|mdx)$/, "");

      entries.push({
        file: path.relative(process.cwd(), fullPath),
        locale,
        slug,
        path: blogUrlPath(locale, slug),
        data,
        body: content,
      });
    }
  }

  return entries;
}
