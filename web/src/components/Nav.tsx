"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import type { Release } from "@/lib/release";

export function Nav({ release }: { release: Release }) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => setOpen(false), [pathname]);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const links = [
    { href: "/faq/", label: "FAQ" },
    { href: "/docs/", label: "docs" },
    { href: "/blog/", label: "blog" },
  ];

  return (
    <header className="nav">
      <div className="nav-inner">
        <Link href="/" className="wordmark" aria-label="ironpet home">
          <img src="/icon.png" alt="" width={28} height={28} />
          <span>ironpet</span>
        </Link>
        <nav className="nav-links" aria-label="Main">
          {links.map((link) => (
            <Link key={link.href} href={link.href} aria-current={pathname.startsWith(link.href) ? "page" : undefined}>
              {link.label}
            </Link>
          ))}
          <div className="nav-menu" ref={menuRef}>
            <button type="button" aria-expanded={open} aria-haspopup="true" onClick={() => setOpen((v) => !v)}>
              download
              <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
                <path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </button>
            {open && (
              <div className="nav-dropdown">
                <a href={release.dmgUrl}>
                  <strong>Mac with Apple silicon</strong>
                  <span>{release.version ? `IronPet ${release.version} · DMG` : "Latest DMG"}</span>
                </a>
                <Link href="/download/#homebrew">
                  <strong>Homebrew</strong>
                  <span>brew install --cask</span>
                </Link>
                <Link href="/download/#source">
                  <strong>Mac with Intel</strong>
                  <span>Build from source</span>
                </Link>
              </div>
            )}
          </div>
        </nav>
      </div>
    </header>
  );
}
