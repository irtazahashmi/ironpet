import type { Metadata } from "next";
import Link from "next/link";
import { formatDate, getPosts } from "@/lib/content";

export const metadata: Metadata = {
  title: "Blog",
  description: "News and notes from the people building ironpet.",
};

export default function BlogIndex() {
  const posts = getPosts();
  return (
    <div className="page">
      <header className="page-head">
        <h1>Blog</h1>
        <p>News and notes from building ironpet.</p>
      </header>
      <div className="post-list">
        {posts.map((post) => (
          <Link key={post.slug} href={`/blog/${post.slug}/`} className="post-card">
            <p className="post-meta">
              <time dateTime={post.date}>{formatDate(post.date)}</time>
            </p>
            <h2>{post.title}</h2>
            <p>{post.description}</p>
          </Link>
        ))}
        {posts.length === 0 && <p className="muted">No posts yet.</p>}
      </div>
    </div>
  );
}
