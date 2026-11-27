import type { MetadataRoute } from "next";
import { getDocs, getPosts } from "@/lib/content";
import { site } from "@/lib/site";

export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  const pages = ["/", "/download/", "/docs/", "/faq/", "/blog/"].map((path) => ({ url: `${site.url}${path}` }));
  const docs = getDocs().map((doc) => ({ url: `${site.url}/docs/${doc.slug}/` }));
  const posts = getPosts().map((post) => ({ url: `${site.url}/blog/${post.slug}/`, lastModified: post.date || undefined }));
  return [...pages, ...docs, ...posts];
}
