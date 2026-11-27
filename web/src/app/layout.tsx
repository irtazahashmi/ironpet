import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Footer } from "@/components/Footer";
import { Nav } from "@/components/Nav";
import { latestRelease } from "@/lib/release";
import { site } from "@/lib/site";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: { default: "ironpet: a desktop pet for your coding agents", template: "%s · ironpet" },
  description:
    "ironpet is a macOS desktop pet that watches Cursor, Claude Code, Codex and other coding agents, tells you when they need you, and chats with them. Free and open source.",
  icons: { icon: "/icon.png", apple: "/icon.png" },
  openGraph: { siteName: "ironpet", type: "website" },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#fbfbfc" },
    { media: "(prefers-color-scheme: dark)", color: "#0d1015" },
  ],
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  const release = await latestRelease();
  return (
    <html lang="en">
      <body>
        <a className="skip" href="#main">
          Skip to content
        </a>
        <Nav release={release} />
        <main id="main">{children}</main>
        <Footer release={release} />
      </body>
    </html>
  );
}
