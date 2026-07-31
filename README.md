# B2B Content Site

基于 [deployment-plan.md](deployment-plan.md) 的 B2B 内容站骨架：
Astro + Content Collections + Markdown/MDX，纯静态输出，
Docker 多阶段构建，GitHub Actions → GHCR → VPS 蓝绿部署，
询盘全部走 WhatsApp Click-to-Chat。

## 常用命令

```bash
npm install            # 安装依赖
npm run dev            # 本地开发 http://localhost:4321
npm run check          # Astro + TypeScript 检查
npm run validate:content   # 内容与内链校验（构建前）
npm run build          # 构建 + SEO 校验（构建后自动执行）
npm run preview        # 预览构建产物
```

## 新站点需要替换的内容

| 位置 | 内容 |
| --- | --- |
| `src/config/site.ts` | 品牌名、tagline、默认 CTA |
| `src/config/taxonomies.mjs` | 分类词表、作者 |
| `src/config/navigation.ts` | 导航 |
| `.env` / GitHub Variables | `SITE_URL`、WhatsApp 号码、GTM ID |
| `.github/workflows/ci-deploy.yml` | `IMAGE_NAME`（GHCR 镜像名） |
| `public/favicon.svg`、`public/images/brand/` | 品牌视觉 |
| `src/styles/global.css` | `:root` 里的颜色变量 |

## 写文章

在 `src/content/blog/<locale>/` 下新建 `.md` 或 `.mdx`：

- 文件名即 URL slug（`en/foo.md` → `/blog/foo/`，`zh/foo.md` → `/zh/blog/foo/`）
- Frontmatter 字段由 `src/content.config.ts` 强制校验
- 同一篇文章的多语言版本使用相同 `translationKey`，hreflang 自动互链
- `category` / `author` 必须出自 `src/config/taxonomies.mjs`
- 头图放 `public/images/blog/`，必须填 `featuredImageAlt`
- `draft: true` 的文章不会构建；`noindex: true` 的文章不进 Sitemap

## 部署

推送到 `main` 后由 GitHub Actions 构建镜像并部署，详见
[deployment-plan.md](deployment-plan.md)（服务器端脚本、Nginx、Cloudflare
配置都在里面）。
