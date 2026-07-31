# GitHub 推送后自动部署的 Docker 博客平台完整方案

> **修订记录（2026-07-31 评审后修正）**
>
> 1. 清除 Nginx / Cloudflare 配置中被 Markdown 链接污染的域名（`[www.example.com](...)` → `www.example.com`）。
> 2. 容器内 Nginx 增加"非斜杠 URL 301 到带斜杠"规则，消除双 URL 重复内容（并保留 UTM 等查询参数）。
> 3. `site.ts` 对 WhatsApp 号码增加构建期 fail-fast 校验，缺失时立即报出可读错误。
> 4. Zod 导入确认为 `astro/zod`（Astro 7 起 `import { z } from "astro:content"` 已被官方废弃，`astro/zod` 是公开导出入口，Zod 4）；`z.string().url()` 在 Zod 4 中已废弃，改用 `z.url()`。
> 5. 宿主机 Nginx 补充 `proxy_set_header Connection "";`，使 upstream keepalive 真正生效。
> 6. 标注 `http2 on;` 需要 Nginx ≥ 1.25.1，旧版本使用 `listen 443 ssl http2;`。
> 7. Cloudflare 侧开启 HSTS。
> 8. 健康检查只保留 Dockerfile 内一份定义，Compose 不再重复。
> 9. 部署脚本的 revision 校验改用 jq（服务器需预装 jq、curl），并标注参数校验为安全边界、禁止删改。
> 10. CI 去重：validate 只在 PR 阶段运行；push 到 main 时由 Docker 构建内部的同样检查把关，避免同一提交构建两次。
> 11. 监控层新增外部拨测（UptimeRobot / Cloudflare Health Checks）。
> 12. 验收标准同步新增上述各项。

## 一、方案定版

针对你的使用场景，最终建议采用：

> **Astro 7 + TypeScript + Markdown/MDX + Docker 多阶段构建 + 非 Root Nginx 容器 + GitHub Actions + GHCR + Docker Compose 蓝绿发布 + 宿主机 Nginx + Cloudflare CDN/SSL/WAF + WhatsApp CTA**

截至 2026 年 7 月，Node.js 24 是 LTS 版本，官方计划维护至 2028 年 4 月；Astro 当前文档已经进入 v7（最低要求 Node 22，Node 24 满足）。Astro 默认适合构建静态页面，Content Collections 能对 Markdown、MDX 文章进行结构校验、类型检查和构建期查询，非常适合博客、采购指南、产品知识库和 B2B 内容站。([Node.js][1])

这套方案明确**不使用**：

```text
Contact Form
Contact API
表单数据库
Node.js 生产运行时
WordPress
独立图片 CDN
单独购买 CDN
Kubernetes
生产服务器现场编译
```

最终网站是一个完全无状态的内容站：

```text
代码与文章在 GitHub
Docker 镜像在 GHCR
静态页面在 Nginx 容器
流量入口在 Cloudflare
客户询盘进入 WhatsApp
```

---

# 二、总体架构

```text
Codex / 本地开发电脑
        │
        │ 编写代码、Markdown、MDX、图片
        │ git push / Pull Request
        ▼
GitHub Repository
        │
        ├─ Pull Request
        │    ├─ 内容字段校验
        │    ├─ TypeScript 检查
        │    ├─ 内链和图片检查
        │    ├─ Astro 构建测试
        │    └─ 不部署生产
        │
        └─ Merge / Push 到 main
             ▼
       GitHub Actions
             │
             ├─ 安装依赖
             ├─ 校验内容
             ├─ 构建 Astro 静态站
             ├─ 构建 Docker 镜像
             ├─ 推送 GHCR
             └─ 获得不可变镜像 Digest
                     │
                     ▼
      ghcr.io/organization/site@sha256:...
                     │
                     │ SSH 发送部署指令
                     ▼
              Linux 服务器
                     │
          ┌──────────┴──────────┐
          │                     │
    Blue 容器              Green 容器
  127.0.0.1:18081       127.0.0.1:18082
          │                     │
          └──────────┬──────────┘
                     │
              宿主机 Nginx
          只指向当前活动容器
                     │
                     ▼
                 Cloudflare
          DNS / SSL / CDN / WAF
                     │
                     ▼
                   访客
                     │
                     ▼
              WhatsApp CTA
```

---

# 三、各层职责划分

| 层级    | 技术                                     | 职责                       |
| ----- | -------------------------------------- | ------------------------ |
| 内容层   | Markdown / MDX                         | 文章、采购指南、案例、FAQ           |
| 内容模型  | Astro Content Collections              | Frontmatter 校验、类型安全、分类查询 |
| 页面层   | Astro 7 + TypeScript                   | 静态 HTML 生成               |
| SEO 层 | Sitemap、RSS、Canonical、hreflang、JSON-LD | 搜索引擎和答案引擎可读性             |
| 转化层   | WhatsApp Click-to-Chat                 | 承接询盘                     |
| 分析层   | GTM / GA4                              | WhatsApp 点击及来源追踪         |
| 构建层   | GitHub Actions + Docker BuildKit       | 自动检查和镜像构建                |
| 镜像仓库  | GHCR                                   | 保存每个发布版本                 |
| 运行层   | 非 Root Nginx Docker 容器                 | 提供静态页面                   |
| 编排层   | Docker Compose                         | 启动 Blue/Green 容器         |
| 流量切换  | 宿主机 Nginx                              | 蓝绿切换和回滚                  |
| 边缘层   | Cloudflare                             | CDN、SSL、WAF、缓存、DDoS 防护   |

Docker 镜像最终通过 Digest 部署，例如：

```text
ghcr.io/platinumbear/vantora-site@sha256:4a8d...
```

Digest 是内容寻址标识，相同镜像内容对应确定的 Digest，因此比可变的 `latest` 标签更适合生产部署和回滚。([Docker Documentation][2])

---

# 四、网站部署形态

## 4.1 优先使用主域名子目录

从 SEO 集中度考虑，博客最好位于品牌主站：

```text
https://www.example.com/blog/
```

而不是：

```text
https://blog.example.com/
```

推荐让 Astro 同时管理：

```text
首页
产品页
解决方案页
应用场景页
博客
案例
关于我们
WhatsApp CTA
```

这样所有内容共享同一个域名权重、设计系统、导航体系和内链结构。

## 4.2 一个品牌一个 GitHub 仓库

推荐：

```text
vantora-site
nitorwood-site
mobile-wholesale-site
formulaunch-site
```

不建议第一阶段将所有品牌放入一个 Monorepo。一个站点构建失败时，不应阻塞其他站点发布。

等三个以上网站结构稳定后，再建立：

```text
b2b-content-site-starter
```

作为统一模板。

---

# 五、GitHub 仓库结构

```text
b2b-content-site/
├── .github/
│   └── workflows/
│       └── ci-deploy.yml
│
├── docker/
│   └── site.conf
│
├── scripts/
│   ├── validate-content.mjs
│   ├── validate-links.mjs
│   └── validate-seo.mjs
│
├── public/
│   ├── images/
│   │   ├── blog/
│   │   ├── products/
│   │   └── brand/
│   ├── favicon.ico
│   ├── robots.txt
│   └── llms.txt
│
├── src/
│   ├── components/
│   │   ├── Header.astro
│   │   ├── Footer.astro
│   │   ├── SeoHead.astro
│   │   ├── Breadcrumbs.astro
│   │   ├── ArticleCard.astro
│   │   ├── ArticleCTA.astro
│   │   ├── WhatsAppCTA.astro
│   │   ├── MobileWhatsAppBar.astro
│   │   ├── DesktopWhatsAppButton.astro
│   │   ├── TableOfContents.astro
│   │   ├── RelatedArticles.astro
│   │   └── FAQ.astro
│   │
│   ├── config/
│   │   ├── site.ts
│   │   ├── navigation.ts
│   │   └── taxonomies.ts
│   │
│   ├── content/
│   │   └── blog/
│   │       ├── en/
│   │       ├── ar/
│   │       ├── pl/
│   │       └── zh/
│   │
│   ├── layouts/
│   │   ├── BaseLayout.astro
│   │   └── ArticleLayout.astro
│   │
│   ├── pages/
│   │   ├── index.astro
│   │   ├── blog/
│   │   ├── category/
│   │   ├── tag/
│   │   ├── author/
│   │   ├── rss.xml.ts
│   │   └── 404.astro
│   │
│   └── content.config.ts
│
├── astro.config.mjs
├── Dockerfile
├── .dockerignore
├── package.json
├── package-lock.json
└── tsconfig.json
```

---

# 六、Astro 基础配置

```javascript
// astro.config.mjs
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import sitemap from "@astrojs/sitemap";

const site = process.env.SITE_URL;

if (!site) {
  throw new Error("SITE_URL is required during build.");
}

export default defineConfig({
  site,
  output: "static",
  trailingSlash: "always",
  integrations: [
    mdx(),
    sitemap(),
  ],
  i18n: {
    locales: ["en", "ar", "pl", "zh"],
    defaultLocale: "en",
    routing: {
      prefixDefaultLocale: false,
    },
  },
});
```

Astro 的 `site` 配置用于生成 Sitemap、Canonical 等绝对地址；官方 Sitemap 集成会扫描静态生成的路由并生成 Sitemap。([Astro Documentation][3])

不需要多语言时，删除 `i18n` 配置即可。

---

# 七、博客内容模型

## 7.1 Content Collections 配置

```typescript
// src/content.config.ts
// Astro 7 起 `import { z } from "astro:content"` 已废弃，
// 官方指定从 "astro/zod" 导入（Zod 4）。
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

const ctaSchema = z.object({
  label: z.string().min(3).max(80),
  topic: z.string().min(3).max(160),
  sourceCode: z
    .string()
    .regex(/^[A-Z0-9-]+$/),
});

const sourceSchema = z.object({
  title: z.string().min(3),
  publisher: z.string().optional(),
  url: z.url(),
  accessedAt: z.coerce.date().optional(),
});

const faqSchema = z.object({
  question: z.string().min(5),
  answer: z.string().min(10),
});

const blog = defineCollection({
  loader: glob({
    base: "./src/content/blog",
    pattern: "**/*.{md,mdx}",
  }),
  schema: z.object({
    title: z.string().min(10).max(120),
    description: z.string().min(50).max(200),
    locale: z.enum(["en", "ar", "pl", "zh"]),
    translationKey: z.string().min(3),
    publishedAt: z.coerce.date(),
    updatedAt: z.coerce.date().optional(),
    author: z
      .string()
      .regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/),
    category: z
      .string()
      .regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/),
    tags: z
      .array(z.string())
      .min(1)
      .max(12),
    featuredImage: z
      .string()
      .startsWith("/images/"),
    featuredImageAlt: z
      .string()
      .min(5)
      .max(180),
    draft: z.boolean().default(false),
    noindex: z.boolean().default(false),
    featured: z.boolean().default(false),
    canonical: z
      .url()
      .optional(),
    cta: ctaSchema.optional(),
    faq: z.array(faqSchema).optional(),
    sources: z.array(sourceSchema).optional(),
  }),
});

export const collections = {
  blog,
};
```

Astro 当前 Content Collections 使用 Loader 加载本地 Markdown/MDX，并通过 Zod 4 Schema 实现构建期验证、编辑器补全和 TypeScript 类型安全。Astro 7 起 `z` 从公开入口 `astro/zod` 导入（`astro:content` 的 `z` 导出已废弃）。([Astro Documentation][4])

## 7.2 文章文件命名

让文件路径决定 URL，避免同时维护文件名和 Slug：

```text
src/content/blog/en/how-to-wholesale-mobile-phones-from-china.md
```

生成：

```text
/blog/how-to-wholesale-mobile-phones-from-china/
```

不要在 Frontmatter 里再维护一份独立 `slug`，否则容易出现：

```text
文件名 URL
vs.
Frontmatter Slug
```

不一致的问题。

## 7.3 文章示例

```markdown
---
title: "How to Wholesale Mobile Phones from China"
description: "A practical sourcing guide for mobile phone wholesalers, distributors and independent retailers."
locale: "en"
translationKey: "wholesale-mobile-phones-from-china"
publishedAt: "2026-07-30"
updatedAt: "2026-07-30"
author: "jack-lau"
category: "sourcing-guides"
tags:
  - mobile-phone-wholesale
  - china-sourcing
  - phone-distributor
featuredImage: "/images/blog/mobile-phone-wholesale.webp"
featuredImageAlt: "Wholesale mobile phones prepared for international distribution"
draft: false
noindex: false
featured: true
cta:
  label: "Request Current Wholesale Prices"
  topic: "wholesale mobile phones from China"
  sourceCode: "BLOG-WHOLESALE-PHONES"
sources:
  - title: "Example source"
    publisher: "Example publisher"
    url: "https://example.org/source"
---

文章正文……
```

---

# 八、SEO/GEO 页面结构

## 8.1 必备页面

```text
/
├── /blog/
├── /blog/article-slug/
├── /category/category-slug/
├── /tag/tag-slug/
├── /author/author-slug/
├── /rss.xml
├── /sitemap-index.xml
├── /robots.txt
└── /404.html
```

## 8.2 每篇文章输出

每个文章页面统一生成：

```text
Title
Meta Description
Canonical
Open Graph
Twitter Card
Article JSON-LD
BreadcrumbList JSON-LD
Organization JSON-LD
发布日期
更新日期
作者
分类
标签
目录
相关文章
来源列表
WhatsApp CTA
```

## 8.3 CI 阻断检查

以下问题直接导致构建失败：

| 检查项                    | 处理 |
| ---------------------- | -- |
| 重复 URL                 | 阻断 |
| 重复 Translation Key     | 阻断 |
| 缺少 Title               | 阻断 |
| 缺少 Description         | 阻断 |
| 图片不存在                  | 阻断 |
| 图片缺少 Alt               | 阻断 |
| 内链 404                 | 阻断 |
| Draft 被加入 Sitemap      | 阻断 |
| `noindex` 页面加入 Sitemap | 阻断 |
| Canonical 指向错误域名       | 阻断 |
| hreflang 缺少回链          | 阻断 |
| 日期格式错误                 | 阻断 |
| 分类不在词表中                | 阻断 |
| 标签拼写变体重复               | 阻断 |

以下只产生警告：

```text
文章没有 CTA
文章没有来源字段
文章过短
Hero 图片过大
正文没有内部链接
没有相关产品页链接
```

---

# 九、WhatsApp CTA 体系

## 9.1 不使用统一的"Contact Us"

CTA 文案要对应采购意图：

| 页面类型        | CTA 文案                              |
| ----------- | ----------------------------------- |
| 手机批发文章      | Request Current Wholesale Prices    |
| 产品页         | Check MOQ and Available Models      |
| Android 定制页 | Discuss Your Android Device Program |
| 木材护理产品页     | Get Private Label Pricing           |
| 案例页         | Discuss a Similar Deployment        |
| 品牌首页        | Tell Us What You Need               |

## 9.2 每个 CTA 自动携带上下文

WhatsApp 预设消息包含：

```text
感兴趣的主题
页面 URL
来源代码
按钮位置
希望客户提供的信息
```

示例：

```text
Hello, I am interested in wholesale mobile phones from China.
Reference: BLOG-WHOLESALE-PHONES-ARTICLE-END
Page: https://www.example.com/blog/how-to-wholesale-mobile-phones-from-china/
Please share your current models, MOQ and wholesale pricing.
```

这样业务员看到消息后，立即知道：

```text
客户来自哪个页面
客户关注什么产品
客户点击了哪个 CTA
客户大概处于什么采购阶段
```

## 9.3 全局配置

号码缺失必须在构建期立即失败，报出可读错误，而不是在组件渲染时抛出难以定位的 `undefined` 异常。注意 Docker 构建中未传入的 ARG 会变成空字符串，所以校验用真值判断（同时拦截 `undefined` 和空串），语言回退用 `||` 而不是 `??`：

```typescript
// src/config/site.ts
function requireEnv(
  value: string | undefined,
  name: string,
): string {
  if (!value) {
    throw new Error(
      `${name} is required at build time.`,
    );
  }
  return value;
}

const defaultNumber = requireEnv(
  import.meta.env.PUBLIC_WHATSAPP_NUMBER,
  "PUBLIC_WHATSAPP_NUMBER",
);

export const siteConfig = {
  name: "Example Brand",
  siteUrl: "https://www.example.com",
  whatsapp: {
    defaultNumber,
    numbersByLocale: {
      en: defaultNumber,
      ar:
        import.meta.env.PUBLIC_WHATSAPP_NUMBER_AR ||
        defaultNumber,
      pl:
        import.meta.env.PUBLIC_WHATSAPP_NUMBER_PL ||
        defaultNumber,
      zh: defaultNumber,
    },
  },
} as const;
```

这些号码最终会出现在网页源码中，所以不属于 Secret，应作为 GitHub Variable 管理。

## 9.4 CTA 组件

```astro
---
// src/components/WhatsAppCTA.astro
import { siteConfig } from "../config/site";

interface Props {
  label: string;
  topic: string;
  sourceCode: string;
  placement:
    | "header"
    | "hero"
    | "article-start"
    | "article-middle"
    | "article-end"
    | "mobile-bar"
    | "floating";
  locale?: "en" | "ar" | "pl" | "zh";
  class?: string;
}

const {
  label,
  topic,
  sourceCode,
  placement,
  locale = "en",
  class: className = "",
} = Astro.props;

const number =
  siteConfig.whatsapp.numbersByLocale[locale] ??
  siteConfig.whatsapp.defaultNumber;

const cleanNumber = number.replace(/\D/g, "");

const baseUrl =
  Astro.site ?? new URL(siteConfig.siteUrl);

const pageUrl = new URL(
  Astro.url.pathname,
  baseUrl,
).toString();

const message = [
  `Hello, I am interested in ${topic}.`,
  "",
  `Reference: ${sourceCode}-${placement.toUpperCase()}`,
  `Page: ${pageUrl}`,
  "",
  "Please share more information, MOQ and current pricing.",
].join("\n");

const href =
  `https://wa.me/${cleanNumber}` +
  `?text=${encodeURIComponent(message)}`;
---

<a
  href={href}
  target="_blank"
  rel="noopener noreferrer"
  class:list={["whatsapp-cta", className]}
  data-whatsapp-cta
  data-whatsapp-topic={topic}
  data-whatsapp-source={sourceCode}
  data-whatsapp-placement={placement}
  data-whatsapp-locale={locale}
  aria-label={`${label} via WhatsApp`}
>
  {label}
</a>
```

## 9.5 CTA 布局

### 桌面端

```text
Header 右上角 CTA
Hero 主 CTA
文章中部 CTA
文章结尾 CTA
右下角轻量悬浮按钮
```

### 移动端

```text
Hero CTA
文章内 CTA
底部固定 WhatsApp 按钮
```

移动端不建议同时存在：

```text
底部固定栏
+
右下角悬浮按钮
+
自动弹窗
```

否则会遮挡正文。

---

# 十、WhatsApp 点击追踪

网站无法可靠判断用户打开 WhatsApp 后是否真正发送了消息，因此应区分：

```text
WhatsApp Click
vs.
Actual WhatsApp Message
vs.
Qualified Inquiry
```

点击事件属于网站侧微转化；实际询盘通过预设消息中的 `Reference` 与 WhatsApp 标签进行归因。

## 10.1 DataLayer 事件

在全局 Layout 中加入：

```html
<script is:inline>
  document.addEventListener("click", function (event) {
    const element = event.target.closest(
      "[data-whatsapp-cta]"
    );

    if (!element) return;

    window.dataLayer = window.dataLayer || [];

    window.dataLayer.push({
      event: "whatsapp_click",
      page_path: window.location.pathname,
      page_title: document.title,
      whatsapp_topic:
        element.dataset.whatsappTopic || "",
      whatsapp_source:
        element.dataset.whatsappSource || "",
      cta_placement:
        element.dataset.whatsappPlacement || "",
      page_locale:
        element.dataset.whatsappLocale || "",
    });
  });
</script>
```

## 10.2 GTM / GA4 事件参数

```text
event_name: whatsapp_click

parameters:
page_path
page_title
whatsapp_topic
whatsapp_source
cta_placement
page_locale
```

## 10.3 业务归因代码

建议每个页面拥有唯一代码：

```text
BLOG-WHOLESALE-PHONES
PRODUCT-HONOR-WHOLESALE
SOLUTION-ANDROID-KIOSK
CASE-CUSTOMS-HANDHELD
PRODUCT-EXTERIOR-WOOD-OIL
```

最终 WhatsApp 消息中显示：

```text
Reference:
SOLUTION-ANDROID-KIOSK-HERO
```

业务员可在 WhatsApp Business 中添加标签：

```text
Website Lead
Vantora
Custom Android
Qualified
Quoted
Sample
Won
Lost
```

---

# 十一、Docker 多阶段构建

## 11.1 Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.7

FROM node:24-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY . .

ARG SITE_URL
ARG BUILD_SHA
ARG PUBLIC_WHATSAPP_NUMBER
ARG PUBLIC_WHATSAPP_NUMBER_AR
ARG PUBLIC_WHATSAPP_NUMBER_PL
ARG PUBLIC_GTM_ID

ENV SITE_URL=${SITE_URL}
ENV PUBLIC_WHATSAPP_NUMBER=${PUBLIC_WHATSAPP_NUMBER}
ENV PUBLIC_WHATSAPP_NUMBER_AR=${PUBLIC_WHATSAPP_NUMBER_AR}
ENV PUBLIC_WHATSAPP_NUMBER_PL=${PUBLIC_WHATSAPP_NUMBER_PL}
ENV PUBLIC_GTM_ID=${PUBLIC_GTM_ID}

RUN mkdir -p public/_meta \
    && printf '{"revision":"%s"}\n' "${BUILD_SHA}" \
       > public/_meta/build.json

RUN npm run check
RUN npm run validate:content
RUN npm run lint --if-present
RUN npm test --if-present
RUN npm run build

FROM nginxinc/nginx-unprivileged:stable-alpine AS runtime

COPY docker/site.conf \
  /etc/nginx/conf.d/default.conf

COPY --from=builder \
  /app/dist \
  /usr/share/nginx/html

EXPOSE 8080

# 运行期健康检查唯一定义处；Compose 不再重复定义，避免两处配置漂移。
HEALTHCHECK \
  --interval=15s \
  --timeout=3s \
  --start-period=5s \
  --retries=5 \
  CMD wget -q -O /dev/null \
      http://127.0.0.1:8080/healthz || exit 1
```

最终镜像只有：

```text
Nginx
静态 HTML
CSS
JavaScript
图片
Sitemap
RSS
```

不会包含：

```text
Node.js 运行时
源代码
npm 缓存
TypeScript 编译器
Git 历史
GitHub Secrets
数据库密码
SMTP 密码
CRM Token
```

NGINX 官方维护的 unprivileged 镜像默认使用非特权用户运行，将默认监听端口调整为 8080，并把 pid 文件和临时目录移到了 `/tmp`——因此配合只读根文件系统时，只需要挂载 tmpfs 到 `/tmp`（见第十三节），且只能覆盖 `conf.d/default.conf`，不要覆盖主 `nginx.conf`。([GitHub][5])

## 11.2 `.dockerignore`

```dockerignore
.git
.github
node_modules
dist
.astro
.env
.env.*
!.env.example
npm-debug.log
README.md
docs
compose*.yml
```

---

# 十二、容器内部 Nginx 配置

```nginx
# docker/site.conf
server {
    listen 8080;
    listen [::]:8080;

    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    charset utf-8;
    server_tokens off;
    etag on;

    access_log /dev/stdout;
    error_log /dev/stderr warn;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types
        text/plain
        text/css
        text/xml
        application/json
        application/javascript
        application/xml
        application/rss+xml
        image/svg+xml;

    location = /healthz {
        access_log off;
        default_type text/plain;
        add_header Cache-Control
            "no-store"
            always;
        return 200 "ok\n";
    }

    location = /_meta/build.json {
        try_files $uri =404;
        add_header Cache-Control
            "no-store"
            always;
    }

    location /_astro/ {
        try_files $uri =404;
        expires 1y;
        add_header Cache-Control
            "public, max-age=31536000, immutable"
            always;
    }

    location /images/ {
        try_files $uri =404;
        expires 30d;
        add_header Cache-Control
            "public, max-age=2592000"
            always;
    }

    location ~* ^/(?:robots\.txt|rss\.xml|sitemap.*\.xml)$ {
        try_files $uri =404;
        add_header Cache-Control
            "public, max-age=300, must-revalidate"
            always;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }

    # trailingSlash: "always" 的配套规则：
    # 不带斜杠且不含扩展名的路径 301 到带斜杠版本，
    # 避免 /blog/post 与 /blog/post/ 同时返回 200 造成重复内容。
    # $is_args$args 保留 UTM 等查询参数。
    # /healthz 为精确匹配（location =），优先级更高，不受影响。
    location ~ ^([^.]*[^/])$ {
        return 301 $1/$is_args$args;
    }

    location / {
        try_files
            $uri
            $uri/
            $uri/index.html
            =404;
        add_header Cache-Control
            "public, max-age=0, must-revalidate"
            always;
    }

    error_page 404 /404.html;

    location = /404.html {
        internal;
    }
}
```

这里的缓存职责是：

```text
/_astro/ 哈希资源：浏览器缓存一年
/images/：浏览器缓存30天
HTML：浏览器每次重新验证
Cloudflare：负责边缘缓存 HTML
```

---

# 十三、服务器端 Docker Compose

服务器需预装：`docker`（含 compose 插件）、`curl`、`jq`。

服务器目录：

```text
/opt/sites/example-site/
├── compose.yml
├── state/
│   ├── active
│   ├── blue.image
│   ├── green.image
│   └── releases.log
└── logs/
```

`compose.yml`：

```yaml
services:
  site:
    image: ${IMAGE_REF}
    container_name: ${SITE_ID}-${COLOR}
    restart: unless-stopped
    init: true
    read_only: true
    tmpfs:
      - /tmp:size=32m,mode=1777
    ports:
      - "127.0.0.1:${HOST_PORT}:8080"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    pids_limit: 100
    mem_limit: 128m
    cpus: 0.50
    # 健康检查继承镜像内的 HEALTHCHECK 定义（见 Dockerfile），
    # 此处不重复定义，避免两处配置漂移。
    stop_grace_period: 15s
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
```

Docker Compose 原生支持 Healthcheck 和只读根文件系统；`cap_drop`、`no-new-privileges` 等配置可进一步减少静态容器的运行权限。([Docker Documentation][6])

---

# 十四、蓝绿发布结构

| 环境         | 地址                | 状态        |
| ---------- | ----------------- | --------- |
| Blue       | `127.0.0.1:18081` | 当前版本或候选版本 |
| Green      | `127.0.0.1:18082` | 当前版本或候选版本 |
| Host Nginx | `443`             | 永远指向活动颜色  |

第一次部署：

```text
Blue 启动
→ 健康检查
→ Nginx 指向 Blue
```

第二次部署：

```text
Green 启动新版本
→ 健康检查
→ 校验 Git Commit
→ Nginx 指向 Green
→ Blue 保持运行
```

第三次部署：

```text
Blue 替换为更新版本
→ 健康检查
→ Nginx 指向 Blue
→ Green 保持运行
```

因此始终保留：

```text
当前版本
+
上一稳定版本
```

---

# 十五、宿主机 Nginx

> 注意：`http2 on;` 语法要求 Nginx ≥ 1.25.1。发行版自带的旧版本（如 Ubuntu 22.04 的 1.18）需改用官方软件源安装新版，或使用旧语法 `listen 443 ssl http2;`。

## 15.1 Blue Upstream

```nginx
# /etc/nginx/site-upstreams/example-blue.conf
upstream example_site_active {
    server 127.0.0.1:18081;
    keepalive 32;
}
```

## 15.2 Green Upstream

```nginx
# /etc/nginx/site-upstreams/example-green.conf
upstream example_site_active {
    server 127.0.0.1:18082;
    keepalive 32;
}
```

活动配置是软链接：

```text
/etc/nginx/conf.d/00-example-active.conf
    ↓
/etc/nginx/site-upstreams/example-blue.conf
```

或者：

```text
/etc/nginx/conf.d/00-example-active.conf
    ↓
/etc/nginx/site-upstreams/example-green.conf
```

## 15.3 域名配置

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name example.com www.example.com;

    return 301 https://www.example.com$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name www.example.com;

    ssl_certificate
        /etc/ssl/cloudflare/example-origin.pem;
    ssl_certificate_key
        /etc/ssl/cloudflare/example-origin-key.pem;

    location = /healthz {
        proxy_pass http://example_site_active/healthz;
        proxy_http_version 1.1;
        # 清空 Connection 头，upstream keepalive 才会生效
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        add_header Cache-Control
            "no-store"
            always;
    }

    location / {
        proxy_pass http://example_site_active;
        proxy_http_version 1.1;
        # 清空 Connection 头，upstream keepalive 才会生效
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP
            $remote_addr;
        proxy_set_header X-Forwarded-For
            $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto
            $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }

    add_header X-Content-Type-Options
        "nosniff"
        always;
    add_header Referrer-Policy
        "strict-origin-when-cross-origin"
        always;
    add_header Permissions-Policy
        "camera=(), microphone=(), geolocation=()"
        always;
}
```

HSTS（`Strict-Transport-Security`）不在源站配置，统一在 Cloudflare 边缘开启（见第二十三节），避免源站与边缘双重配置漂移。

再增加一个仅供服务器内部检查的端口：

```nginx
server {
    listen 127.0.0.1:18080;
    server_name _;

    location / {
        proxy_pass http://example_site_active;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
```

Nginx reload 会先检查新配置；配置有效后启动新 Worker，并让旧 Worker 完成已有请求后退出，因此适合进行近零停机的蓝绿切换。([Nginx][7])

---

# 十六、蓝绿切换脚本

```bash
#!/usr/bin/env bash
# /usr/local/sbin/example-site-switch

set -Eeuo pipefail

COLOR="${1:-}"

ACTIVE_LINK="/etc/nginx/conf.d/00-example-active.conf"

case "$COLOR" in
  blue)
    TARGET="/etc/nginx/site-upstreams/example-blue.conf"
    ;;
  green)
    TARGET="/etc/nginx/site-upstreams/example-green.conf"
    ;;
  *)
    echo "Usage: example-site-switch blue|green"
    exit 2
    ;;
esac

OLD_TARGET="$(readlink -f "$ACTIVE_LINK" 2>/dev/null || true)"

ln -sfn "$TARGET" "$ACTIVE_LINK"

if ! nginx -t; then
  echo "Nginx configuration validation failed."

  if [[ -n "$OLD_TARGET" ]]; then
    ln -sfn "$OLD_TARGET" "$ACTIVE_LINK"
  else
    rm -f "$ACTIVE_LINK"
  fi

  exit 1
fi

if ! systemctl reload nginx; then
  echo "Nginx reload failed."

  if [[ -n "$OLD_TARGET" ]]; then
    ln -sfn "$OLD_TARGET" "$ACTIVE_LINK"
    nginx -t
    systemctl reload nginx || true
  fi

  exit 1
fi

echo "Traffic switched to ${COLOR}."
```

权限：

```bash
sudo chown root:root \
  /usr/local/sbin/example-site-switch

sudo chmod 750 \
  /usr/local/sbin/example-site-switch
```

---

# 十七、生产部署脚本

```bash
#!/usr/bin/env bash
# /usr/local/sbin/example-site-deploy

set -Eeuo pipefail

SITE_ID="example-site"
BASE_DIR="/opt/sites/${SITE_ID}"
STATE_DIR="${BASE_DIR}/state"
COMPOSE_FILE="${BASE_DIR}/compose.yml"

EXPECTED_IMAGE_PREFIX="ghcr.io/your-org/example-site@sha256:"

IMAGE_REF="${1:-}"
REVISION="${2:-}"

# ============================================================
# 安全边界：deploy 用户可通过 sudo 无密码执行本脚本，
# 以下参数校验是阻止其部署任意镜像的唯一防线，禁止删改或"简化"。
# ============================================================

if [[ "$IMAGE_REF" != "${EXPECTED_IMAGE_PREFIX}"* ]]; then
  echo "Rejected image reference."
  exit 2
fi

DIGEST="${IMAGE_REF#*@sha256:}"

if ! [[ "$DIGEST" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Invalid image digest."
  exit 2
fi

if ! [[ "$REVISION" =~ ^[a-f0-9]{40}$ ]]; then
  echo "Invalid Git revision."
  exit 2
fi

mkdir -p "$STATE_DIR"

exec 9>"${STATE_DIR}/deploy.lock"

if ! flock -n 9; then
  echo "Another deployment is running."
  exit 1
fi

ACTIVE="$(cat "${STATE_DIR}/active" 2>/dev/null || true)"

case "$ACTIVE" in
  blue)
    TARGET="green"
    TARGET_PORT="18082"
    ;;
  green)
    TARGET="blue"
    TARGET_PORT="18081"
    ;;
  *)
    TARGET="blue"
    TARGET_PORT="18081"
    ACTIVE=""
    ;;
esac

ENV_FILE="$(mktemp)"

cleanup() {
  rm -f "$ENV_FILE"
}

trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
IMAGE_REF=${IMAGE_REF}
SITE_ID=${SITE_ID}
COLOR=${TARGET}
HOST_PORT=${TARGET_PORT}
EOF

PROJECT_NAME="${SITE_ID}-${TARGET}"
CONTAINER_NAME="${SITE_ID}-${TARGET}"

echo "Deploying ${IMAGE_REF} to ${TARGET}."

docker compose \
  --project-name "$PROJECT_NAME" \
  --env-file "$ENV_FILE" \
  --file "$COMPOSE_FILE" \
  pull

docker compose \
  --project-name "$PROJECT_NAME" \
  --env-file "$ENV_FILE" \
  --file "$COMPOSE_FILE" \
  up \
  --detach \
  --force-recreate

HEALTHY=0

for attempt in $(seq 1 30); do
  STATUS="$(
    docker inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' \
      "$CONTAINER_NAME" \
      2>/dev/null || true
  )"

  if [[ "$STATUS" == "healthy" ]]; then
    HEALTHY=1
    break
  fi

  if [[ "$STATUS" == "unhealthy" ]]; then
    break
  fi

  sleep 2
done

if [[ "$HEALTHY" != "1" ]]; then
  echo "New container is not healthy."

  docker logs \
    --tail=200 \
    "$CONTAINER_NAME" || true

  # 注意：失败的容器会以 unhealthy 状态留在目标端口上，
  # 便于现场排查；下一次部署的 --force-recreate 会覆盖它。
  exit 1
fi

curl \
  --fail \
  --silent \
  --show-error \
  "http://127.0.0.1:${TARGET_PORT}/healthz" \
  >/dev/null

BUILD_META="$(
  curl \
    --fail \
    --silent \
    --show-error \
    "http://127.0.0.1:${TARGET_PORT}/_meta/build.json"
)"

if ! jq -e \
  --arg revision "$REVISION" \
  '.revision == $revision' \
  <<< "$BUILD_META" \
  >/dev/null; then
  echo "Build revision verification failed."
  exit 1
fi

/usr/local/sbin/example-site-switch "$TARGET"

if ! curl \
  --fail \
  --silent \
  --show-error \
  "http://127.0.0.1:18080/healthz" \
  >/dev/null; then
  echo "Host Nginx verification failed."

  if [[ -n "$ACTIVE" ]]; then
    /usr/local/sbin/example-site-switch "$ACTIVE"
  fi

  exit 1
fi

printf '%s\n' "$TARGET" \
  > "${STATE_DIR}/active"

printf '%s\n' "$IMAGE_REF" \
  > "${STATE_DIR}/${TARGET}.image"

printf '%s | %s | %s | %s\n' \
  "$(date --iso-8601=seconds)" \
  "$TARGET" \
  "$REVISION" \
  "$IMAGE_REF" \
  >> "${STATE_DIR}/releases.log"

echo "Deployment succeeded."
echo "Active color: ${TARGET}"
```

---

# 十八、回滚脚本

```bash
#!/usr/bin/env bash
# /usr/local/sbin/example-site-rollback

set -Eeuo pipefail

STATE_DIR="/opt/sites/example-site/state"

ACTIVE="$(cat "${STATE_DIR}/active")"

case "$ACTIVE" in
  blue)
    TARGET="green"
    TARGET_PORT="18082"
    ;;
  green)
    TARGET="blue"
    TARGET_PORT="18081"
    ;;
  *)
    echo "Unknown active color."
    exit 1
    ;;
esac

curl \
  --fail \
  --silent \
  --show-error \
  "http://127.0.0.1:${TARGET_PORT}/healthz" \
  >/dev/null

/usr/local/sbin/example-site-switch "$TARGET"

printf '%s\n' "$TARGET" \
  > "${STATE_DIR}/active"

printf '%s | rollback | %s\n' \
  "$(date --iso-8601=seconds)" \
  "$TARGET" \
  >> "${STATE_DIR}/releases.log"

echo "Rolled back to ${TARGET}."
```

正常回滚只做：

```text
检查旧容器
→ 切换 Nginx Upstream
→ Nginx Graceful Reload
```

不需要重新下载镜像，也不需要重新构建。

---

# 十九、部署用户安全设计

不建议把 GitHub Actions 登录用户直接加入：

```text
docker
```

Docker 官方明确提示，`docker` 用户组实际上授予接近 Root 的权限。([Docker Documentation][8])

更合理的设计：

```text
GitHub Actions
    ↓ SSH
deploy 用户
    ↓ sudo
Root 所有的部署脚本
    ↓
Docker / Nginx
```

`deploy` 用户：

```text
不能修改部署脚本
不能直接运行 Docker
不能修改 Nginx
只能调用固定部署命令
```

Sudoers：

```sudoers
deploy ALL=(root) NOPASSWD: /usr/local/sbin/example-site-deploy *
deploy ALL=(root) NOPASSWD: /usr/local/sbin/example-site-rollback
```

注意 sudoers 中的 `*` 匹配任意参数——这个设计成立的前提，是部署脚本内部对以下各项的严格校验（即脚本开头标注的"安全边界"段落）：

```text
镜像仓库前缀
Digest 格式
Commit SHA 格式
站点目录
允许操作的容器名称
```

---

# 二十、GHCR 权限

GitHub Actions 推送镜像时使用：

```text
GITHUB_TOKEN
```

并授予：

```yaml
permissions:
  contents: read
  packages: write
```

Linux 服务器拉取私有镜像时，使用只具备：

```text
read:packages
```

权限的 PAT Classic。

GitHub 官方文档支持在 Actions 中使用自动生成的 `GITHUB_TOKEN` 发布 GHCR 镜像；服务器侧拉取私有容器镜像则可使用具有相应 Packages 权限的 Token。([GitHub Docs][9])

服务器 Root 用户执行一次：

```bash
echo "$GHCR_READ_TOKEN" \
  | sudo docker login ghcr.io \
      --username "your-github-user" \
      --password-stdin
```

认证信息保存在：

```text
/root/.docker/config.json
```

---

# 二十一、GitHub Actions 完整工作流

CI 分工：**PR 阶段由 `validate` 把关；push 到 main 时跳过 `validate`，由 Docker 构建内部完全相同的 check / validate / build 步骤把关**（见 Dockerfile），避免同一提交把全部检查和构建重复执行两遍。

```yaml
name: Validate, Build and Deploy

on:
  pull_request:
    branches:
      - main
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

env:
  IMAGE_NAME: ghcr.io/your-org/example-site

jobs:
  validate:
    name: Validate Content and Build Site
    # 只作为 PR 质量门禁运行。
    # push 到 main 时，Docker 构建内部会执行同样的检查与构建。
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v6

      - name: Set up Node.js
        uses: actions/setup-node@v7
        with:
          node-version: "24"
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Check Astro and TypeScript
        run: npm run check

      - name: Validate content
        run: npm run validate:content

      - name: Lint
        run: npm run lint --if-present

      - name: Test
        run: npm test --if-present

      - name: Build static site
        run: npm run build
        env:
          SITE_URL: ${{ vars.SITE_URL }}
          PUBLIC_WHATSAPP_NUMBER: ${{ vars.PUBLIC_WHATSAPP_NUMBER }}
          PUBLIC_WHATSAPP_NUMBER_AR: ${{ vars.PUBLIC_WHATSAPP_NUMBER_AR }}
          PUBLIC_WHATSAPP_NUMBER_PL: ${{ vars.PUBLIC_WHATSAPP_NUMBER_PL }}
          PUBLIC_GTM_ID: ${{ vars.PUBLIC_GTM_ID }}

  build_image:
    name: Build and Push Docker Image
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image_ref: ${{ steps.image_ref.outputs.image_ref }}
    steps:
      - name: Checkout repository
        uses: actions/checkout@v6

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          build-args: |
            SITE_URL=${{ vars.SITE_URL }}
            BUILD_SHA=${{ github.sha }}
            PUBLIC_WHATSAPP_NUMBER=${{ vars.PUBLIC_WHATSAPP_NUMBER }}
            PUBLIC_WHATSAPP_NUMBER_AR=${{ vars.PUBLIC_WHATSAPP_NUMBER_AR }}
            PUBLIC_WHATSAPP_NUMBER_PL=${{ vars.PUBLIC_WHATSAPP_NUMBER_PL }}
            PUBLIC_GTM_ID=${{ vars.PUBLIC_GTM_ID }}
          tags: |
            ${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.IMAGE_NAME }}:latest
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Generate immutable image reference
        id: image_ref
        env:
          IMAGE_DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          echo \
            "image_ref=${IMAGE_NAME}@${IMAGE_DIGEST}" \
            >> "$GITHUB_OUTPUT"

  deploy:
    name: Deploy Production
    if: github.event_name != 'pull_request'
    needs:
      - build_image
    runs-on: ubuntu-latest
    environment:
      name: production
      url: ${{ vars.SITE_URL }}
    concurrency:
      group: example-site-production
      cancel-in-progress: false
    permissions:
      contents: read
    steps:
      - name: Configure SSH
        env:
          SSH_PRIVATE_KEY:
            ${{ secrets.PROD_SSH_PRIVATE_KEY }}
          SSH_KNOWN_HOSTS:
            ${{ secrets.PROD_SSH_KNOWN_HOSTS }}
        run: |
          install -m 700 -d "$HOME/.ssh"

          printf '%s\n' "$SSH_PRIVATE_KEY" \
            > "$HOME/.ssh/id_ed25519"

          chmod 600 "$HOME/.ssh/id_ed25519"

          printf '%s\n' "$SSH_KNOWN_HOSTS" \
            > "$HOME/.ssh/known_hosts"

          chmod 600 "$HOME/.ssh/known_hosts"

      - name: Deploy immutable image
        env:
          PROD_HOST: ${{ secrets.PROD_HOST }}
          PROD_PORT: ${{ secrets.PROD_PORT }}
          PROD_USER: ${{ secrets.PROD_USER }}
          IMAGE_REF:
            ${{ needs.build_image.outputs.image_ref }}
          BUILD_SHA:
            ${{ github.sha }}
        run: |
          ssh \
            -i "$HOME/.ssh/id_ed25519" \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes \
            -p "$PROD_PORT" \
            "${PROD_USER}@${PROD_HOST}" \
            "sudo /usr/local/sbin/example-site-deploy '${IMAGE_REF}' '${BUILD_SHA}'"

      - name: Purge Cloudflare cache
        env:
          CF_ZONE_ID:
            ${{ secrets.CF_ZONE_ID }}
          CF_API_TOKEN:
            ${{ secrets.CF_CACHE_PURGE_TOKEN }}
        run: |
          RESPONSE="$(
            curl \
              --fail \
              --silent \
              --show-error \
              --retry 3 \
              --request POST \
              "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
              --header "Authorization: Bearer ${CF_API_TOKEN}" \
              --header "Content-Type: application/json" \
              --data '{"purge_everything":true}'
          )"

          echo "$RESPONSE" \
            | jq -e '.success == true'

      - name: Verify public health
        env:
          SITE_URL: ${{ vars.SITE_URL }}
          BUILD_SHA: ${{ github.sha }}
        run: |
          curl \
            --fail \
            --silent \
            --show-error \
            --retry 6 \
            --retry-all-errors \
            "${SITE_URL}/healthz"

          BUILD_META="$(
            curl \
              --fail \
              --silent \
              --show-error \
              --retry 6 \
              --retry-all-errors \
              "${SITE_URL}/_meta/build.json?revision=${BUILD_SHA}"
          )"

          echo "$BUILD_META" \
            | jq -e \
                --arg revision "$BUILD_SHA" \
                '.revision == $revision'
```

GitHub Actions 可以用 Environments 隔离生产 Secrets、限制部署分支和增加审批；Concurrency 可以避免同一生产环境同时执行多个部署。([GitHub Docs][10])

正式环境建议把第三方 Action 从：

```yaml
docker/build-push-action@v6
```

改成经过核验的完整 Commit SHA。GitHub 官方同样建议生产工作流固定 Action Commit SHA，避免标签内容变化。([GitHub Docs][9])

---

# 二十二、GitHub Variables 和 Secrets

## 22.1 Repository Variables

```text
SITE_URL
PUBLIC_WHATSAPP_NUMBER
PUBLIC_WHATSAPP_NUMBER_AR
PUBLIC_WHATSAPP_NUMBER_PL
PUBLIC_GTM_ID
```

示例：

```text
SITE_URL=https://www.example.com
PUBLIC_WHATSAPP_NUMBER=8613812345678
PUBLIC_GTM_ID=GTM-XXXXXXX
```

## 22.2 Production Environment Secrets

```text
PROD_HOST
PROD_PORT
PROD_USER
PROD_SSH_PRIVATE_KEY
PROD_SSH_KNOWN_HOSTS
CF_ZONE_ID
CF_CACHE_PURGE_TOKEN
```

这里不需要：

```text
DATABASE_URL
SMTP_PASSWORD
CRM_API_SECRET
```

因为网站没有后端和表单服务。

---

# 二十三、Cloudflare 配置

## 23.1 DNS

```text
A
Name: @
Value: Linux服务器IP
Proxy: Proxied

CNAME
Name: www
Target: example.com
Proxy: Proxied
```

必须开启橙色云朵。

## 23.2 SSL/TLS

设置：

```text
SSL/TLS
→ Overview
→ Full (strict)
```

源站安装：

```text
Cloudflare Origin Certificate
```

或受公开 CA 信任的证书。

Cloudflare 推荐使用 Full 或 Full（strict）；Full（strict）会加密 Cloudflare 到源站的连接，并验证源站证书。([Cloudflare Docs][11])

同时在此开启 HSTS：

```text
SSL/TLS
→ Edge Certificates
→ HTTP Strict Transport Security (HSTS)
→ Enable
   Max-Age: 6 months（稳定后再延长并勾选 includeSubDomains / preload）
```

注意：开启 HSTS 前确认全站（含所有子域）已稳定运行 HTTPS，一旦浏览器记住 HSTS，回退 HTTP 会直接无法访问。

## 23.3 缓存规则一：绕过健康检查

匹配：

```text
/healthz
/_meta/build.json
```

设置：

```text
Cache eligibility:
Bypass cache
```

## 23.4 缓存规则二：Astro 哈希资源

匹配：

```text
/_astro/*
```

设置：

```text
Cache eligibility:
Eligible for cache

Edge Cache TTL:
1 year

Browser Cache TTL:
1 year
```

## 23.5 缓存规则三：图片

匹配：

```text
/images/*
```

设置：

```text
Edge Cache TTL:
30 days

Browser Cache TTL:
Respect origin
```

## 23.6 缓存规则四：Sitemap 与 RSS

匹配：

```text
/robots.txt
/rss.xml
/sitemap.xml
/sitemap-index.xml
/sitemap-*.xml
```

设置：

```text
Edge Cache TTL:
15 minutes

Browser Cache TTL:
Respect origin
```

## 23.7 缓存规则五：HTML

匹配：

```text
Host = www.example.com
Method = GET or HEAD
排除 /healthz
排除 /_meta/*
```

设置：

```text
Cache eligibility:
Eligible for cache

Edge Cache TTL:
1 day

Browser Cache TTL:
Respect origin
```

Cloudflare 默认主要按照文件扩展名缓存静态资源；要缓存静态 HTML，需要通过 Cache Rule 将页面设为 Eligible for cache，也就是通常所说的 Cache Everything。因为本方案没有登录状态、购物车、账户或个性化内容，所以 HTML 边缘缓存是合适的。([Cloudflare Docs][12])

---

# 二十四、Cloudflare 缓存清理策略

## 第一阶段

网站文章数量和流量尚不大时，每次部署：

```json
{
  "purge_everything": true
}
```

优点：

```text
逻辑最简单
不会遗漏分类页
不会遗漏Tag页
不会遗漏相关文章变化
不会遗漏Sitemap
```

## 第二阶段

文章数量和流量扩大后，改成按 URL 清理：

```json
{
  "files": [
    "https://www.example.com/",
    "https://www.example.com/blog/",
    "https://www.example.com/blog/changed-article/",
    "https://www.example.com/category/sourcing-guides/",
    "https://www.example.com/sitemap-index.xml",
    "https://www.example.com/rss.xml"
  ]
}
```

Cloudflare 支持按 URL 和全站 Purge，并明确推荐优先使用更精确的单 URL 清理；全站清理会让后续请求重新回源。([Cloudflare Docs][13])

---

# 二十五、Cloudflare 源站防护

## 第一层

```text
Cloudflare Proxy
+
Full (strict)
+
Cloudflare Origin Certificate
```

## 第二层

服务器防火墙：

```text
80/443：
只允许 Cloudflare IP 段

18081/18082：
只监听 127.0.0.1

SSH：
只允许密钥登录
禁止 Root 登录
```

## 第三层

可增加：

```text
Authenticated Origin Pulls
```

确保源站 HTTPS 请求来自 Cloudflare。

Cloudflare 官方建议使用代理 DNS、隐藏源站 IP、限制源站只接受 Cloudflare 网络连接；Authenticated Origin Pulls 能进一步验证回源请求。([Cloudflare Docs][14])

---

# 二十六、图片架构

第一阶段直接使用：

```text
public/images/
```

图片进入：

```text
GitHub
→ Docker镜像
→ Linux
→ Cloudflare边缘缓存
```

不需要：

```text
R2
S3
OSS
独立图片域名
额外CDN
```

建议图片规范：

| 图片类型         | 建议          |
| ------------ | ----------- |
| Hero 主图      | WebP 或 AVIF |
| 文章正文图        | 最大宽度 1600px |
| 文章列表缩略图      | 单独生成较小版本    |
| 文件名          | 英文语义化       |
| 单张图片         | 尽量低于 300KB  |
| Width/Height | 明确输出，减少布局位移 |
| 首屏图片         | 不 Lazy Load |
| 非首屏图片        | Lazy Load   |

图片更新时使用新文件名：

```text
wood-oil-guide-v2.webp
```

不要覆盖：

```text
wood-oil-guide.webp
```

否则浏览器和 Cloudflare 长缓存可能继续显示旧图。

当出现以下情况时，再迁移 Cloudflare R2：

```text
Git 仓库因图片明显膨胀
Docker 镜像接近 1GB
每次构建上传时间明显增长
图片数量达到数千张
非技术人员需要独立上传图片
```

---

# 二十七、监控体系

## 容器层

```bash
docker ps
docker inspect example-site-blue
docker inspect example-site-green
```

## 本机端口层

```bash
curl http://127.0.0.1:18081/healthz
curl http://127.0.0.1:18082/healthz
```

## Nginx 层

```bash
curl http://127.0.0.1:18080/healthz
```

## 公网层

```bash
curl https://www.example.com/healthz
```

## 外部拨测层

以上都是手动检查，网站半夜挂掉不会有人知道。必须配置至少一个外部拨测：

```text
UptimeRobot（免费档即可）
或 Cloudflare Health Checks

监控地址：
https://www.example.com/healthz

检查间隔：1–5 分钟
告警渠道：邮件 / Telegram / 企业微信
```

## 版本层

```bash
curl https://www.example.com/_meta/build.json
```

返回：

```json
{
  "revision": "完整Git Commit SHA"
}
```

## Cloudflare 缓存层

检查响应头：

```text
CF-Cache-Status: HIT
CF-Cache-Status: MISS
CF-Cache-Status: BYPASS
```

## 日志层

保留：

```text
GitHub Actions部署记录
GitHub Deployment History
/opt/sites/example-site/state/releases.log
Docker日志
宿主机Nginx访问日志
宿主机Nginx错误日志
Cloudflare Analytics
WhatsApp点击事件
```

已知状态说明：部署失败时，不健康的新容器会保留在目标端口上便于排查（不影响线上流量，流量仍在旧颜色）；下一次部署会自动覆盖它。

---

# 二十八、备份与灾难恢复

网站是无状态的，所以不需要数据库备份。

## GitHub 保存

```text
源代码
Markdown文章
页面模板
Git历史
CI/CD配置
```

## GHCR 保存

```text
历史Docker镜像
Commit标签
镜像Digest
```

## 私有基础设施仓库保存

```text
Nginx配置模板
Docker Compose
部署脚本
回滚脚本
Cloudflare规则说明
服务器初始化脚本
```

## 加密备份

```text
Cloudflare Origin Certificate
Origin Certificate Private Key
SSH部署密钥
GHCR只读Token
```

服务器完全损坏后的恢复流程：

```text
1. 新建Linux服务器
2. 安装Docker和Nginx
3. 恢复Nginx配置
4. 登录GHCR
5. 拉取指定Digest镜像
6. 启动Blue容器
7. 指向Blue
8. 更新Cloudflare源站IP
```

不需要从旧服务器抢救源代码或内容。

---

# 二十九、多网站统一架构

对于你的多个项目，可以统一端口：

| 项目          |  Blue | Green |  内部检查 |
| ----------- | ----: | ----: | ----: |
| Vantora     | 18101 | 18102 | 18100 |
| 手机批发站       | 18201 | 18202 | 18200 |
| NitorWood   | 18301 | 18302 | 18300 |
| FormuLaunch | 18401 | 18402 | 18400 |
| 企业 AI 站     | 18501 | 18502 | 18500 |

服务器结构：

```text
/opt/sites/
├── vantora/
├── mobile-wholesale/
├── nitorwood/
├── formulauch/
└── ai-business/
```

每个项目：

```text
一个GitHub仓库
一个GHCR镜像
两个Docker容器
一个Nginx域名配置
一组Cloudflare规则
一个WhatsApp配置
```

后续可建立：

```text
GitHub Template Repository
+
Reusable GitHub Actions Workflow
+
统一服务器部署脚本
```

每新建一个网站只需要替换：

```text
品牌名称
域名
WhatsApp号码
语言
颜色和字体
导航
分类词表
CTA文案
GHCR镜像名称
服务器端口
Cloudflare Zone
```

---

# 三十、推荐发布流程

```text
Codex创建feature分支
        ↓
创建或修改文章
        ↓
提交Pull Request
        ↓
自动检查内容与构建
        ↓
检查通过
        ↓
合并main
        ↓
GitHub Actions构建Docker镜像
        ↓
推送GHCR
        ↓
获得Image Digest
        ↓
部署到非活动颜色
        ↓
容器Healthcheck
        ↓
验证Commit SHA
        ↓
Nginx蓝绿切换
        ↓
Cloudflare Purge
        ↓
公网Healthcheck
        ↓
正式上线
```

Codex 批量生成文章时，不建议直接获得生产分支写权限。更安全的是：

```text
Codex提交PR
→ CI检查
→ 人工或规则审核
→ 合并main
→ 自动部署
```

---

# 三十一、验收标准

这套系统完成后，应逐项满足：

## 代码与内容

* `main` 受到保护；
* Pull Request 必须通过构建检查；
* Frontmatter 缺字段会失败；
* 重复 URL 会失败；
* 图片缺失会失败；
* Draft 不会进入生产；
* `noindex` 页面不会进入 Sitemap；
* WhatsApp 号码缺失时构建立即失败并报出变量名。

## Docker

* GitHub Actions 中构建；
* 生产服务器不执行 `npm install`；
* 生产服务器不执行 `npm run build`；
* 最终容器没有 Node.js 应用进程；
* 容器使用非 Root 用户；
* 容器根文件系统只读；
* 容器只监听 `127.0.0.1`；
* 部署使用 Image Digest。

## 发布

* 新版本先部署到非活动容器；
* Healthcheck 失败不切换流量；
* Commit SHA 不匹配不切换；
* Nginx 切换前执行配置检查；
* 旧容器在发布后继续运行；
* 可以一条命令回滚。

## URL 与 SEO

* 不带斜杠的 URL 301 到带斜杠版本（如 `/blog/post` → `/blog/post/`）；
* 301 跳转保留查询参数（UTM 不丢失）；
* 同一页面只有一个返回 200 的 URL。

## Cloudflare

* DNS 为 Proxied；
* SSL 为 Full（strict）；
* HSTS 已开启；
* HTML 已设置边缘缓存；
* `/_astro/` 长缓存；
* `/healthz` 不缓存；
* 发布后自动 Purge；
* 源站 18081/18082 不暴露公网。

## 监控

* 外部拨测已配置（UptimeRobot 或 Cloudflare Health Checks）；
* 网站不可用时能在 5 分钟内收到告警。

## WhatsApp

* CTA 自动携带页面 URL；
* CTA 自动携带来源代码；
* CTA 自动携带按钮位置；
* GTM 收到 `whatsapp_click`；
* 移动端只有一个固定 WhatsApp 操作入口；
* 实际 WhatsApp 询盘可通过 Reference 归因。

---

# 三十二、最终推荐架构

最终定版为：

```text
Astro 7
+ TypeScript
+ Markdown / MDX
+ Astro Content Collections
+ Sitemap / RSS / Canonical / hreflang
+ WhatsApp Click-to-Chat
+ 页面级来源代码
+ GTM / GA4点击追踪
+ Node.js 24 LTS构建环境
+ Docker Multi-stage Build
+ Unprivileged Nginx Runtime
+ GitHub Actions
+ GitHub Container Registry
+ Image Digest部署
+ Docker Compose
+ Blue-Green双容器
+ 宿主机Nginx Graceful Switch
+ Cloudflare DNS
+ Cloudflare Full (strict)
+ Cloudflare CDN
+ Cloudflare HTML Cache Rule
+ 发布后自动Purge
+ Cloudflare源站防护
+ 外部拨测告警
```

核心原则是：

> **GitHub 保存源代码和内容，GitHub Actions 负责构建，GHCR 保存不可变镜像，Linux 只运行容器，Nginx 负责蓝绿切换，Cloudflare 负责全球分发，WhatsApp 负责承接询盘。**

这套方案已经足以作为 Vantora、手机批发站、NitorWood 等 B2B 网站的统一内容站基础设施，不需要再增加 Contact Form、业务数据库、独立 CDN 或 Kubernetes。

[1]: https://nodejs.org/en/blog/release/v24.11.0 "Node.js 24.11.0 (LTS)"
[2]: https://docs.docker.com/engine/containers/run/ "Running containers"
[3]: https://docs.astro.build/en/reference/configuration-reference/ "Configuration Reference - Astro Docs"
[4]: https://docs.astro.build/en/guides/content-collections/ "Content collections | Docs"
[5]: https://github.com/nginx/docker-nginx-unprivileged/blob/main/README.md "docker-nginx-unprivileged README"
[6]: https://docs.docker.com/reference/compose-file/services/ "Define services in Docker Compose | Docker Docs"
[7]: https://nginx.org/en/docs/beginners_guide.html "Beginner's Guide"
[8]: https://docs.docker.com/engine/install/linux-postinstall/ "Linux post-installation steps for Docker Engine"
[9]: https://docs.github.com/actions/guides/publishing-docker-images "Publishing Docker images - GitHub Docs"
[10]: https://docs.github.com/actions/deployment/about-deployments/deploying-with-github-actions "Deploying with GitHub Actions - GitHub Docs"
[11]: https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/ "Encryption modes · Cloudflare SSL/TLS docs"
[12]: https://developers.cloudflare.com/cache/concepts/default-cache-behavior/ "Default Cache Behavior"
[13]: https://developers.cloudflare.com/cache/how-to/purge-cache/ "Purge cache"
[14]: https://developers.cloudflare.com/fundamentals/security/protect-your-origin-server/ "Protect your origin server"
