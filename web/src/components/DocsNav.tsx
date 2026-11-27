import Link from "next/link";
import { docSections, type Doc } from "@/lib/content";

export function DocsNav({ docs, current }: { docs: Doc[]; current?: string }) {
  return (
    <nav className="docs-nav" aria-label="Docs">
      {docSections.map((section) => {
        const pages = docs.filter((d) => d.section === section);
        if (pages.length === 0) return null;
        return (
          <div key={section}>
            <h2>{section}</h2>
            {pages.map((d) => (
              <Link key={d.slug} href={`/docs/${d.slug}/`} aria-current={d.slug === current ? "page" : undefined}>
                {d.title}
              </Link>
            ))}
          </div>
        );
      })}
    </nav>
  );
}
