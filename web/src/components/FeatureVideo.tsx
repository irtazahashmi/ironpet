"use client";

import { useEffect, useRef, useState } from "react";

export type Clip = {
  /** File name in public/videos, without the extension: `<name>.mp4` and its poster `<name>.jpg`. */
  name: string;
  width: number;
  height: number;
  /** What the clip shows, for screen readers. */
  label: string;
};

/**
 * A muted, looping clip that plays only while it is on screen. With Reduce Motion it stays on its poster until the
 * visitor presses Play, and the button pauses it at any time.
 */
export function FeatureVideo({ clip }: { clip: Clip }) {
  const video = useRef<HTMLVideoElement>(null);
  const paused = useRef(false);
  const [playing, setPlaying] = useState(false);

  useEffect(() => {
    const element = video.current;
    if (!element) return;
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) element.pause();
        else if (!motion.matches && !paused.current) element.play().catch(() => {});
      },
      { threshold: 0.35 },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  function toggle() {
    const element = video.current;
    if (!element) return;
    if (element.paused) {
      paused.current = false;
      element.play().catch(() => {});
    } else {
      paused.current = true;
      element.pause();
    }
  }

  return (
    <div className="clip">
      <video
        ref={video}
        width={clip.width}
        height={clip.height}
        poster={`/videos/${clip.name}.jpg`}
        aria-label={clip.label}
        muted
        loop
        playsInline
        preload="none"
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
      >
        <source src={`/videos/${clip.name}.mp4`} type="video/mp4" />
      </video>
      <button type="button" className="clip-toggle" onClick={toggle} aria-label={playing ? "Pause video" : "Play video"}>
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
          {playing ? (
            <path d="M4 2.5h2.5v11H4zM9.5 2.5H12v11H9.5z" fill="currentColor" />
          ) : (
            <path d="M4.5 2.2v11.6L13.5 8z" fill="currentColor" />
          )}
        </svg>
      </button>
    </div>
  );
}
