// URL 规则的唯一定义处：页面组件、Astro 配置和校验脚本共用，
// 避免"文件名 URL vs 生成 URL"出现多份实现。

export const LOCALES = ["en", "ar", "pl", "zh"];
export const DEFAULT_LOCALE = "en";

/**
 * @param {string} id Content Collections 条目 id，如 "en/how-to-x"
 * @returns {string} locale
 */
export function localeFromId(id) {
  return id.split("/")[0];
}

/**
 * @param {string} id Content Collections 条目 id
 * @returns {string} slug（不含 locale 前缀）
 */
export function slugFromId(id) {
  return id.split("/").slice(1).join("/");
}

/**
 * @param {string} locale
 * @param {string} slug
 * @returns {string} 站内路径，默认语言不带前缀
 */
export function blogUrlPath(locale, slug) {
  return locale === DEFAULT_LOCALE
    ? `/blog/${slug}/`
    : `/${locale}/blog/${slug}/`;
}
