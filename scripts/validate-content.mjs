// 内容校验（构建前）：方案 §8.3 的阻断项与警告项。
// 阻断项 exit 1；警告项只打印。

import fs from "node:fs";
import path from "node:path";
import {
  scanBlogContent,
  loadDotEnv,
} from "./lib/content-meta.mjs";
import {
  categories,
  authors,
} from "../src/config/taxonomies.mjs";

const env = { ...loadDotEnv(), ...process.env };
const siteUrl = env.SITE_URL || "";

const entries = scanBlogContent();
const errors = [];
const warnings = [];

const REQUIRED_FIELDS = [
  "title",
  "description",
  "locale",
  "translationKey",
  "publishedAt",
  "author",
  "category",
  "tags",
  "featuredImage",
  "featuredImageAlt",
];

const categorySlugs = new Set(categories.map((c) => c.slug));
const authorSlugs = new Set(authors.map((a) => a.slug));

const seenPaths = new Map();
const seenTranslationKeys = new Map();

const normalizeTag = (tag) =>
  String(tag).toLowerCase().replace(/[\s_]+/g, "-");

for (const entry of entries) {
  const { file, data } = entry;

  for (const field of REQUIRED_FIELDS) {
    if (
      data[field] === undefined ||
      data[field] === null ||
      data[field] === ""
    ) {
      errors.push(`${file}: 缺少必填字段 "${field}"`);
    }
  }

  if (data.locale && data.locale !== entry.locale) {
    errors.push(
      `${file}: Frontmatter locale "${data.locale}" 与目录 "${entry.locale}" 不一致`,
    );
  }

  // 重复 URL
  if (seenPaths.has(entry.path)) {
    errors.push(
      `${file}: URL "${entry.path}" 与 ${seenPaths.get(entry.path)} 重复`,
    );
  } else {
    seenPaths.set(entry.path, file);
  }

  // 同一语言内重复 Translation Key
  if (data.translationKey) {
    const key = `${entry.locale}:${data.translationKey}`;
    if (seenTranslationKeys.has(key)) {
      errors.push(
        `${file}: translationKey "${data.translationKey}" 在 ${entry.locale} 中与 ${seenTranslationKeys.get(key)} 重复`,
      );
    } else {
      seenTranslationKeys.set(key, file);
    }
  }

  // 日期
  for (const field of ["publishedAt", "updatedAt"]) {
    if (data[field] !== undefined) {
      const date = new Date(data[field]);
      if (Number.isNaN(date.valueOf())) {
        errors.push(`${file}: "${field}" 不是有效日期`);
      }
    }
  }
  if (data.publishedAt && data.updatedAt) {
    if (new Date(data.updatedAt) < new Date(data.publishedAt)) {
      errors.push(`${file}: updatedAt 早于 publishedAt`);
    }
  }

  // 分类与作者必须在词表中
  if (data.category && !categorySlugs.has(data.category)) {
    errors.push(
      `${file}: 分类 "${data.category}" 不在 src/config/taxonomies.mjs 词表中`,
    );
  }
  if (data.author && !authorSlugs.has(data.author)) {
    errors.push(
      `${file}: 作者 "${data.author}" 不在 src/config/taxonomies.mjs 词表中`,
    );
  }

  // 标签拼写变体重复
  if (Array.isArray(data.tags)) {
    const normalized = new Map();
    for (const tag of data.tags) {
      const norm = normalizeTag(tag);
      if (normalized.has(norm) && normalized.get(norm) !== tag) {
        errors.push(
          `${file}: 标签 "${tag}" 与 "${normalized.get(norm)}" 是拼写变体重复`,
        );
      }
      normalized.set(norm, tag);
    }
  }

  // 头图存在性
  if (
    typeof data.featuredImage === "string" &&
    data.featuredImage.startsWith("/")
  ) {
    const imagePath = path.join("public", data.featuredImage);
    if (!fs.existsSync(imagePath)) {
      errors.push(
        `${file}: featuredImage "${data.featuredImage}" 在 public/ 中不存在`,
      );
    }
  }

  // Canonical 域名
  if (data.canonical && siteUrl) {
    if (!String(data.canonical).startsWith(siteUrl)) {
      errors.push(
        `${file}: canonical "${data.canonical}" 不属于 SITE_URL "${siteUrl}"`,
      );
    }
  }

  // ---- 警告项 ----
  if (!data.cta) {
    warnings.push(`${file}: 没有 CTA 字段`);
  }
  if (!data.sources || data.sources.length === 0) {
    warnings.push(`${file}: 没有来源字段`);
  }

  const wordCount =
    entry.locale === "zh"
      ? entry.body.replace(/\s/g, "").length
      : entry.body.split(/\s+/).filter(Boolean).length;
  if (wordCount < 300) {
    warnings.push(`${file}: 正文过短（约 ${wordCount} 词/字）`);
  }

  if (!/\]\(\//.test(entry.body)) {
    warnings.push(`${file}: 正文没有内部链接`);
  }
}

// hreflang 回链由 ArticleLayout 根据 translationKey 自动双向生成，
// 无需在此单独校验；构建后的 Canonical / Sitemap 检查见 validate-seo.mjs。

if (warnings.length > 0) {
  console.log("⚠️  警告（不阻断）：");
  for (const warning of warnings) console.log(`   ${warning}`);
  console.log("");
}

if (errors.length > 0) {
  console.error("❌ 内容校验失败：");
  for (const error of errors) console.error(`   ${error}`);
  process.exit(1);
}

console.log(`✅ 内容校验通过：${entries.length} 篇文章`);
