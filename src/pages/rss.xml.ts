// src/pages/rss.xml.ts
import rss from "@astrojs/rss";
import { getCollection } from "astro:content";
import type { APIContext } from "astro";
import { siteConfig } from "../config/site";
import { blogUrlPath, slugFromId } from "../lib/paths.mjs";

export async function GET(context: APIContext) {
  const posts = (
    await getCollection(
      "blog",
      (entry) => entry.data.locale === "en" && !entry.data.draft,
    )
  ).sort(
    (a, b) => b.data.publishedAt.valueOf() - a.data.publishedAt.valueOf(),
  );

  return rss({
    title: siteConfig.name,
    description: siteConfig.tagline,
    site: context.site ?? siteConfig.siteUrl,
    items: posts.map((post) => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.publishedAt,
      link: blogUrlPath(post.data.locale, slugFromId(post.id)),
    })),
  });
}
