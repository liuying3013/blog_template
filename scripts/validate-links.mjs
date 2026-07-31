// 内链与图片校验（构建前）：
// 正文中指向站内的 Markdown 链接必须落在已知路径上；
// 引用的本地图片必须存在于 public/。

import fs from "node:fs";
import path from "node:path";
import { scanBlogContent } from "./lib/content-meta.mjs";
import {
  categories,
  authors,
} from "../src/config/taxonomies.mjs";
import { DEFAULT_LOCALE } from "../src/lib/paths.mjs";

const entries = scanBlogContent();
const errors = [];

// 站内已知路径集合
const knownPaths = new Set(["/", "/blog/", "/rss.xml"]);

for (const entry of entries) {
  if (entry.data.draft) continue;
  knownPaths.add(entry.path);
  if (entry.locale !== DEFAULT_LOCALE) {
    knownPaths.add(`/${entry.locale}/blog/`);
  }
}

const defaultLocaleEntries = entries.filter(
  (e) => e.locale === DEFAULT_LOCALE && !e.data.draft,
);

for (const category of categories) {
  if (defaultLocaleEntries.some((e) => e.data.category === category.slug)) {
    knownPaths.add(`/category/${category.slug}/`);
  }
}
for (const author of authors) {
  if (defaultLocaleEntries.some((e) => e.data.author === author.slug)) {
    knownPaths.add(`/author/${author.slug}/`);
  }
}
for (const entry of defaultLocaleEntries) {
  for (const tag of entry.data.tags ?? []) {
    knownPaths.add(`/tag/${tag}/`);
  }
}

const LINK_PATTERN = /(!?)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;

for (const entry of entries) {
  for (const match of entry.body.matchAll(LINK_PATTERN)) {
    const isImage = match[1] === "!";
    let target = match[2];

    // 只检查站内绝对路径
    if (!target.startsWith("/")) continue;

    // 去掉锚点和查询
    target = target.split("#")[0].split("?")[0];
    if (!target) continue;

    if (isImage || /\.[a-z0-9]+$/i.test(target)) {
      // 静态资源：必须存在于 public/
      const assetPath = path.join("public", target);
      if (!fs.existsSync(assetPath) && !knownPaths.has(target)) {
        errors.push(
          `${entry.file}: 引用的资源 "${target}" 在 public/ 中不存在`,
        );
      }
    } else {
      // 站内页面：必须带尾斜杠且是已知路径
      if (!target.endsWith("/")) {
        errors.push(
          `${entry.file}: 内链 "${target}" 缺少尾斜杠（trailingSlash: always）`,
        );
        continue;
      }
      if (!knownPaths.has(target)) {
        errors.push(
          `${entry.file}: 内链 "${target}" 指向不存在的页面（内链 404）`,
        );
      }
    }
  }
}

if (errors.length > 0) {
  console.error("❌ 内链校验失败：");
  for (const error of errors) console.error(`   ${error}`);
  process.exit(1);
}

console.log("✅ 内链校验通过");
