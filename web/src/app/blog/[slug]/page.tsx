import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { formatDate, getPosts } from "@/lib/content";

type Props = { params: Promise<{ slug: string }> };

export const dynamicParams = false;

export function generateStaticParams() {
  return getPosts().map((p) => ({ slug: p.slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const post = getPosts().find((p) => p.slug === slug);
  return post ? { title: post.title, description: post.description, openGraph: { type: "article" } } : {};
}

export default async function PostPage({ params }: Props) {
  const { slug } = await params;
  const post = getPosts().find((p) => p.slug === slug);
  if (!post) notFound();

  return (
    <article className="page">
      <header className="post-head">
        <p className="post-meta">
          <Link href="/blog/">Blog</Link> · <time dateTime={post.date}>{formatDate(post.date)}</time>
          {post.author && ` · ${post.author}`}
        </p>
        <h1>{post.title}</h1>
        {post.description && <p className="lede">{post.description}</p>}
      </header>
      <div className="prose" dangerouslySetInnerHTML={{ __html: post.html }} />
    </article>
  );
}
