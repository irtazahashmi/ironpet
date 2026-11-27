import Link from "next/link";
import type { Release } from "@/lib/release";
import { site } from "@/lib/site";

export function DownloadButtons({ release, centered = false }: { release: Release; centered?: boolean }) {
  return (
    <div className={`download${centered ? " is-centered" : ""}`}>
      <div className="download-buttons">
        <a className="button primary" href={release.dmgUrl}>
          <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
            <path d="M8 2v8.5M4.5 7 8 10.5 11.5 7M3 13.5h10" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          Download for Mac
        </a>
        <a className="button" href={site.repo}>
          View on GitHub
        </a>
      </div>
      <p className="download-note">
        macOS 14 or later · Apple silicon · Free and open source.{" "}
        <Link href="/download/">Homebrew and Intel Macs</Link>
      </p>
    </div>
  );
}
