// src/config/site.ts

export type Locale = "en" | "ar" | "pl" | "zh";

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
  tagline:
    "B2B sourcing guides and product knowledge from a China-based manufacturer.",
  siteUrl: import.meta.env.SITE_URL ?? "https://www.example.com",
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
    } satisfies Record<Locale, string>,
  },
  // 站点级默认 CTA（首页 / Header / 悬浮按钮使用；
  // 文章页优先使用 Frontmatter 里的 cta 字段）
  defaultCta: {
    label: "Tell Us What You Need",
    topic: "your products and wholesale pricing",
    sourceCode: "SITE",
  },
} as const;
