// src/config/taxonomies.mjs
// 分类与作者词表：文章 Frontmatter 的 category / author 必须出自这里，
// 否则 validate-content.mjs 阻断构建。
// 用 .mjs 而不是 .ts，是为了让 Node 校验脚本与 Astro 页面共用同一份数据。

export const categories = [
  {
    slug: "sourcing-guides",
    title: "Sourcing Guides",
    description:
      "Practical guides for sourcing and importing products from China.",
  },
  {
    slug: "product-guides",
    title: "Product Guides",
    description:
      "In-depth product knowledge for wholesalers and distributors.",
  },
  {
    slug: "industry-insights",
    title: "Industry Insights",
    description:
      "Market trends and analysis for B2B buyers.",
  },
];

export const authors = [
  {
    slug: "jack-lau",
    name: "Jack Lau",
    role: "Sourcing Specialist",
    bio: "Helps international buyers source and customize products from China.",
  },
];
