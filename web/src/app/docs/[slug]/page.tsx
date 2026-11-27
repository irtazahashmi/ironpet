import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { DocsNav } from "@/components/DocsNav";
import { getDocs } from "@/lib/content";

type Props = { params: Promise<{ slug: string }> };

export const dynamicParams = false;

export function generateStaticParams() {
  return getDocs().map((d) => ({ slug: d.slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const doc = getDocs().find((d) => d.slug === slug);
  return doc ? { title: doc.title, description: doc.description } : {};
}

export default async function DocPage({ params }: Props) {
  const { slug } = await params;
  const docs = getDocs();
  const index = docs.findIndex((d) => d.slug === slug);
  if (index < 0) notFound();
  const doc = docs[index];
  const prev = docs[index - 1];
  const next = docs[index + 1];

  return (
    <div className="page docs">
      <DocsNav docs={docs} current={slug} />
      <article>
        <header className="page-head">
          <h1>{doc.title}</h1>
          {doc.description && <p>{doc.description}</p>}
        </header>
        <div className="prose" dangerouslySetInnerHTML={{ __html: doc.html }} />
        <nav className="doc-pager" aria-label="Previous and next page">
          {prev && (
            <Link href={`/docs/${prev.slug}/`}>
              <span>Previous</span>
              {prev.title}
            </Link>
          )}
          {next && (
            <Link href={`/docs/${next.slug}/`} className="next">
              <span>Next</span>
              {next.title}
            </Link>
          )}
        </nav>
      </article>
      {doc.headings.length > 1 && (
        <nav className="toc" aria-label="On this page">
          <h2>On this page</h2>
          {doc.headings.map((h) => (
            <a key={h.id} href={`#${h.id}`}>
              {h.text}
            </a>
          ))}
        </nav>
      )}
    </div>
  );
}
