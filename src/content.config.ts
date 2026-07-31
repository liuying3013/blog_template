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
