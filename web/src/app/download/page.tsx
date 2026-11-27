import type { Metadata } from "next";
import Link from "next/link";
import { latestRelease } from "@/lib/release";
import { site } from "@/lib/site";

export const metadata: Metadata = {
  title: "Download",
  description: "Download ironpet for macOS: a DMG for Apple silicon, Homebrew, or build it from source on any Mac.",
};

export default async function DownloadPage() {
  const release = await latestRelease();
  return (
    <div className="page">
      <header className="page-head">
        <h1>Download ironpet</h1>
        <p>Free and open source. Needs macOS 14 or later and at least one coding agent, signed in.</p>
      </header>

      <div className="download-options">
        <section className="option" id="dmg">
          <span className="option-tag">Mac with Apple silicon</span>
          <h2>Download the app</h2>
          <p>
            Open the DMG and drag IronPet to Applications. On first launch a welcome window asks what Ghost may do; nothing
            outside <code>~/.ironpet</code> changes until you press Start. The app keeps itself up to date.
          </p>
          <a className="button primary" href={release.dmgUrl}>
            {release.version ? `Download IronPet ${release.version}` : "Download the latest DMG"}
          </a>
          <p className="download-note">
            Every DMG has a <code>.sha256</code> file beside it on the <a href={release.notesUrl}>release page</a>.
          </p>
        </section>

        <section className="option" id="homebrew">
          <span className="option-tag">Mac with Apple silicon</span>
          <h2>Homebrew</h2>
          <p>Installs the same notarized release.</p>
          <pre>
            <code>{site.brew}</code>
          </pre>
          <p className="download-note">
            Uninstall with <code>brew uninstall --cask ironpet</code>, adding <code>--zap</code> to delete its preferences
            too.
          </p>
        </section>

        <section className="option" id="source">
          <span className="option-tag">Mac with Intel, or any Mac</span>
          <h2>Build from source</h2>
          <p>
            Needs the Xcode command line tools, <a href="https://bun.sh">Bun</a> and npm. The script checks for them and
            tells you how to fix anything missing, then builds, installs and starts the app.
          </p>
          <pre>
            <code>{`git clone ${site.repo}.git\ncd ironpet\n./scripts/install.sh`}</code>
          </pre>
        </section>
      </div>

      <p className="muted" style={{ marginTop: 32 }}>
        Next: <Link href="/docs/getting-started/">Getting started</Link> walks through the first run and the permissions
        macOS asks for.
      </p>
    </div>
  );
}
