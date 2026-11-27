import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { Marked, type Tokens } from "marked";

const root = path.join(process.cwd(), "content");

export type Heading = { id: string; text: string };

export type Page = {
  slug: string;
  meta: Record<string, string>;
  html: string;
  headings: Heading[];
};

export type Doc = Page & { title: string; description: string; section: string; order: number };
export type Post = Page & { title: string; description: string; date: string; author: string };

export const docSections = ["Basics", "Features", "Reference"];

function slugify(text: string) {
  return text
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .trim()
    .replace(/\s+/g, "-");
}

function frontmatter(source: string): { meta: Record<string, string>; body: string } {
  const match = /^---\n([\s\S]*?)\n---\n?/.exec(source);
  if (!match) return { meta: {}, body: source };
  const meta: Record<string, string> = {};
  for (const line of match[1].split("\n")) {
    const i = line.indexOf(":");
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^["']|["']$/g, "");
  }
  return { meta, body: source.slice(match[0].length) };
}

function render(markdown: string): { html: string; headings: Heading[] } {
  const headings: Heading[] = [];
  const used = new Map<string, number>();
  const marked = new Marked({
    gfm: true,
    renderer: {
      heading({ tokens, depth }: Tokens.Heading) {
        const inner = this.parser.parseInline(tokens);
        const base = slugify(inner) || "section";
        const count = used.get(base) ?? 0;
        used.set(base, count + 1);
        const id = count ? `${base}-${count}` : base;
        if (depth === 2) headings.push({ id, text: inner.replace(/<[^>]+>/g, "") });
        return `<h${depth} id="${id}"><a class="anchor" href="#${id}" aria-hidden="true" tabindex="-1">#</a>${inner}</h${depth}>\n`;
      },
      link({ href, title, tokens }: Tokens.Link) {
        const inner = this.parser.parseInline(tokens);
        const external = /^https?:\/\//.test(href) && !href.startsWith("https://ironpet.ai");
        const attrs = external ? ' target="_blank" rel="noreferrer"' : "";
        return `<a href="${href}"${title ? ` title="${title}"` : ""}${attrs}>${inner}</a>`;
      },
      table(token: Tokens.Table) {
        const head = token.header.map((cell) => `<th>${this.parser.parseInline(cell.tokens)}</th>`).join("");
        const rows = token.rows
          .map((row) => `<tr>${row.map((cell) => `<td>${this.parser.parseInline(cell.tokens)}</td>`).join("")}</tr>`)
          .join("");
        return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>\n`;
      },
    },
  });
  return { html: marked.parse(markdown, { async: false }), headings };
}

function load(dir: string): Page[] {
  const full = path.join(root, dir);
  if (!existsSync(full)) return [];
  return readdirSync(full)
    .filter((name) => name.endsWith(".md"))
    .map((name) => {
      const { meta, body } = frontmatter(readFileSync(path.join(full, name), "utf8"));
      return { slug: name.replace(/\.md$/, ""), meta, ...render(body) };
    });
}

export function getDocs(): Doc[] {
  return load("docs")
    .map((page) => ({
      ...page,
      title: page.meta.title ?? page.slug,
      description: page.meta.description ?? "",
      section: page.meta.section ?? "Features",
      order: Number(page.meta.order ?? 999),
    }))
    .sort((a, b) => a.order - b.order);
}

export function getPosts(): Post[] {
  return load("blog")
    .map((page) => ({
      ...page,
      title: page.meta.title ?? page.slug,
      description: page.meta.description ?? "",
      date: page.meta.date ?? "",
      author: page.meta.author ?? "",
    }))
    .sort((a, b) => b.date.localeCompare(a.date));
}

export type FaqItem = { q: string; a: string };

export function getFaq(): FaqItem[] {
  const file = path.join(root, "faq.json");
  return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as FaqItem[]) : [];
}

export function formatDate(date: string) {
  return new Date(`${date}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}
