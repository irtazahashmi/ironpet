import type { Metadata } from "next";
import Link from "next/link";
import { docSections, getDocs } from "@/lib/content";

export const metadata: Metadata = {
  title: "Docs",
  description: "How to install ironpet and use everything Ghost can do.",
};

export default function DocsIndex() {
  const docs = getDocs();
  return (
    <div className="page">
      <header className="page-head">
        <h1>Docs</h1>
        <p>Everything Ghost can do, and how to set it up. New here? Start with Getting started.</p>
      </header>
      <div className="docs-index">
        {docSections.map((section) => {
          const pages = docs.filter((d) => d.section === section);
          if (pages.length === 0) return null;
          return (
            <section key={section}>
              <h2>{section}</h2>
              <div className="docs-grid">
                {pages.map((d) => (
                  <Link key={d.slug} href={`/docs/${d.slug}/`} className="more-item">
                    <h3>{d.title}</h3>
                    <p>{d.description}</p>
                  </Link>
                ))}
              </div>
            </section>
          );
        })}
      </div>
    </div>
  );
}
