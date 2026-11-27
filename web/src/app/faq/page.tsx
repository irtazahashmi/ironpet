import type { Metadata } from "next";
import Link from "next/link";
import { getFaq } from "@/lib/content";

export const metadata: Metadata = {
  title: "FAQ",
  description: "Answers to common questions about ironpet: agents, privacy, Macs, pets and more.",
};

export default function FaqPage() {
  const faq = getFaq();
  return (
    <div className="page narrow">
      <header className="page-head">
        <h1>Questions, answered.</h1>
        <p>
          Can't find yours? The <Link href="/docs/">docs</Link> go deeper, or ask on{" "}
          <a href="https://github.com/irtazahashmi/ironpet/issues">GitHub</a>.
        </p>
      </header>
      <div className="faq">
        {faq.map((item) => (
          <details key={item.q}>
            <summary>{item.q}</summary>
            <p>{item.a}</p>
          </details>
        ))}
      </div>
    </div>
  );
}
