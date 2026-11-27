import Link from "next/link";
import type { Release } from "@/lib/release";
import { site } from "@/lib/site";

export function Footer({ release }: { release: Release }) {
  return (
    <footer className="footer">
      <div className="footer-inner">
        <div className="footer-brand">
          <span className="wordmark">
            <img src="/icon.png" alt="" width={24} height={24} />
            <span>ironpet</span>
          </span>
          <p>{site.tagline}</p>
          <p className="footer-fine">Free and open source under the MIT license.</p>
        </div>
        <div>
          <h2>Product</h2>
          <a href={release.dmgUrl}>Download for Mac</a>
          <Link href="/download/">All downloads</Link>
          <Link href="/docs/">Docs</Link>
        </div>
        <div>
          <h2>Resources</h2>
          <Link href="/blog/">Blog</Link>
          <Link href="/faq/">FAQ</Link>
          <a href={site.releases}>Release notes</a>
        </div>
        <div>
          <h2>Project</h2>
          <a href={site.repo}>GitHub</a>
          <a href={site.security}>Security</a>
          <a href={site.license}>License</a>
        </div>
      </div>
    </footer>
  );
}
