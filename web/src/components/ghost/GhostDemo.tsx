"use client";

import { useCallback, useEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { cellH, cellPosition, cellW, lookIndex, lookRow, rows, sheet, type Row } from "./atlas";

type Act = "wave" | "working" | "waiting" | "done" | "failed" | "water" | "stretch";
type AgentState = "idle" | "working" | "waiting" | "done" | "failed";
type Point = { x: number; y: number };

type Bubble = {
  id: number;
  title: string;
  body?: ReactNode;
  actions?: { label: string; hint?: string; primary?: boolean; run: () => void }[];
  ttl?: number;
  onExpire?: () => void;
};

const acts: { act: Act; label: string }[] = [
  { act: "working", label: "Agent working" },
  { act: "waiting", label: "Needs you" },
  { act: "done", label: "Done" },
  { act: "failed", label: "CI failed" },
  { act: "water", label: "Water break" },
  { act: "stretch", label: "Stretch" },
  { act: "wave", label: "Wave" },
];

const bubbleWidth = 280;

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), Math.max(min, max));
}

function useReducedMotion() {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(query.matches);
    const onChange = () => setReduced(query.matches);
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, []);
  return reduced;
}

export function GhostDemo() {
  const reduced = useReducedMotion();
  const anchorRef = useRef<HTMLDivElement>(null);
  const [mounted, setMounted] = useState(false);

  const [pos, setPos] = useState<Point | null>(null);
  const posRef = useRef<Point | null>(null);
  /** Set once Ghost has left his spot in the demo, so a resize no longer snaps him back. */
  const freeRef = useRef(false);

  const [row, setRow] = useState<Row>(rows.idle);
  const rowRef = useRef<Row>(rows.idle);
  const [frame, setFrame] = useState(0);
  const [playId, setPlayId] = useState(0);
  const baseRef = useRef<Row>(rows.idle);
  const afterRef = useRef<(() => void) | null>(null);

  const [look, setLook] = useState<number | null>(null);
  const lookTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  const [dragging, setDragging] = useState(false);
  const draggingRef = useRef(false);
  const dragRef = useRef<{ startX: number; startY: number; offX: number; offY: number; lastX: number; moved: boolean } | null>(null);
  const droppedOnce = useRef(false);
  const walkingRef = useRef(false);

  const [bubble, setBubble] = useState<Bubble | null>(null);
  const bubbleRef = useRef<Bubble | null>(null);
  const [agent, setAgent] = useState<AgentState>("idle");

  const move = useCallback((p: Point) => {
    posRef.current = p;
    setPos(p);
  }, []);

  const play = useCallback((next: Row, after?: () => void) => {
    afterRef.current = after ?? null;
    rowRef.current = next;
    setRow(next);
    setFrame(0);
    setPlayId((id) => id + 1);
  }, []);

  const setBase = useCallback(
    (next: Row) => {
      baseRef.current = next;
      play(next);
    },
    [play],
  );

  const say = useCallback((next: Omit<Bubble, "id"> | null) => {
    const value = next ? { ...next, id: Date.now() + Math.random() } : null;
    bubbleRef.current = value;
    setBubble(value);
  }, []);

  // Sit on the demo desktop until someone moves him.
  const anchor = useCallback(() => {
    const el = anchorRef.current;
    if (!el) return;
    if (!freeRef.current) {
      const rect = el.getBoundingClientRect();
      move({ x: rect.left + window.scrollX, y: rect.top + window.scrollY });
    } else if (posRef.current) {
      const maxX = document.documentElement.clientWidth - cellW - 8;
      move({ x: clamp(posRef.current.x, 8, maxX), y: posRef.current.y });
    }
  }, [move]);

  useEffect(() => {
    setMounted(true);
    anchor();
    const observer = new ResizeObserver(anchor);
    observer.observe(document.documentElement);
    window.addEventListener("resize", anchor);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", anchor);
    };
  }, [anchor]);

  // Frame clock, with the app's per-frame durations.
  useEffect(() => {
    const finish = () => {
      const after = afterRef.current;
      afterRef.current = null;
      if (after) after();
      else play(baseRef.current);
    };
    if (reduced) {
      if (row.loops) return;
      const total = row.durations.reduce((a, b) => a + b, 0) * 1000;
      const timer = setTimeout(finish, total);
      return () => clearTimeout(timer);
    }
    const timer = setTimeout(() => {
      if (frame + 1 < row.durations.length) setFrame(frame + 1);
      else if (row.loops) setFrame(0);
      else finish();
    }, row.durations[frame] * 1000);
    return () => clearTimeout(timer);
  }, [row, frame, playId, reduced, play]);

  // Bubbles fade on their own, except the approval, which waits for an answer.
  useEffect(() => {
    if (!bubble?.ttl) return;
    const timer = setTimeout(() => {
      if (bubbleRef.current?.id !== bubble.id) return;
      say(null);
      bubble.onExpire?.();
    }, bubble.ttl);
    return () => clearTimeout(timer);
  }, [bubble, say]);

  const rest = useCallback(() => {
    setAgent("idle");
    setBase(rows.idle);
  }, [setBase]);

  function act(name: Act) {
    walkingRef.current = false;
    switch (name) {
      case "wave":
        play(rows.waving);
        say({ title: "Hi, I'm your pet.", body: "Drag me anywhere. In the app, a click on me opens the chat.", ttl: 5000 });
        break;
      case "working":
        setAgent("working");
        setBase(rows.working);
        say({ title: "demo-app · Claude Code", body: "Working on the flaky login test…", ttl: 6000, onExpire: rest });
        break;
      case "waiting":
        setAgent("waiting");
        setBase(rows.waiting);
        say({
          title: "demo-app wants to run a command",
          body: <code>npm test -- login</code>,
          actions: [
            { label: "Deny", hint: "esc", run: deny },
            { label: "Allow", hint: "⌘↩", primary: true, run: allow },
          ],
        });
        break;
      case "done":
        setAgent("done");
        baseRef.current = rows.idle;
        play(rows.jumping);
        say({ title: "demo-app is done", body: "Edited 3 files · Fixed the flaky login test.", ttl: 6000 });
        break;
      case "failed":
        setAgent("failed");
        setBase(rows.failed);
        say({ title: "CI failed: irtaza/ironpet #84", body: "Ask starts a chat that looks into it.", ttl: 6500, onExpire: rest });
        break;
      case "water":
      case "stretch": {
        const water = name === "water";
        if (agent === "waiting") setAgent("idle");
        baseRef.current = rows.idle;
        play(water ? rows.drinking : rows.stretching);
        say({
          title: water ? "Drink some water" : "Stretch a bit",
          body: water ? "Have a glass of water." : "Stand up, roll your shoulders, stretch your back.",
          ttl: 9000,
          actions: [
            {
              label: "Done",
              primary: true,
              run: () => {
                say(null);
                play(rows.waving);
              },
            },
            { label: "Snooze 10 min", run: () => say({ title: "See you in 10 minutes.", ttl: 2500 }) },
          ],
        });
        break;
      }
    }
  }

  function allow() {
    setAgent("working");
    setBase(rows.working);
    say({ title: "Allowed", body: "The agent runs the tests…", ttl: 2400, onExpire: () => act("done") });
  }

  function deny() {
    rest();
    say({ title: "Denied", body: "Nothing ran, and the agent was told no.", ttl: 3500 });
  }

  // ⌘↩ answers the approval, Esc denies or dismisses, as on the app's cards.
  useEffect(() => {
    if (!bubble?.actions) return;
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        const cancel = bubble.actions?.find((a) => a.hint === "esc");
        if (cancel) cancel.run();
        else say(null);
      } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        bubble.actions?.find((a) => a.primary)?.run();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [bubble, say]);

  // Eyes follow the pointer while he idles.
  useEffect(() => {
    const onMove = (e: globalThis.PointerEvent) => {
      const p = posRef.current;
      if (!p || draggingRef.current) return;
      const dx = e.clientX - (p.x - window.scrollX + cellW / 2);
      const dy = e.clientY - (p.y - window.scrollY + cellH * 0.35);
      const next = Math.hypot(dx, dy) < 56 ? null : lookIndex(dx, dy);
      setLook((prev) => (prev === next ? prev : next));
      clearTimeout(lookTimer.current);
      lookTimer.current = setTimeout(() => setLook(null), 2500);
    };
    window.addEventListener("pointermove", onMove);
    return () => {
      window.removeEventListener("pointermove", onMove);
      clearTimeout(lookTimer.current);
    };
  }, []);

  // Now and then he trots a little way along the page.
  useEffect(() => {
    if (reduced || !mounted) return;
    let timer: ReturnType<typeof setTimeout>;
    let raf = 0;
    const schedule = () => {
      timer = setTimeout(tryWalk, 7000 + Math.random() * 8000);
    };
    const tryWalk = () => {
      const p = posRef.current;
      const onScreen = p && p.y - window.scrollY > -cellH && p.y - window.scrollY < window.innerHeight;
      if (!p || !onScreen || rowRef.current !== rows.idle || draggingRef.current || bubbleRef.current || document.hidden) {
        return schedule();
      }
      const maxX = window.scrollX + document.documentElement.clientWidth - cellW - 12;
      const target = clamp(p.x + (Math.random() < 0.5 ? -1 : 1) * (100 + Math.random() * 220), window.scrollX + 12, maxX);
      if (Math.abs(target - p.x) < 40) return schedule();
      const dir = target > p.x ? 1 : -1;
      freeRef.current = true;
      walkingRef.current = true;
      play(dir > 0 ? rows.runRight : rows.runLeft);
      let last = performance.now();
      const step = (now: number) => {
        if (!walkingRef.current || draggingRef.current) return schedule();
        const dt = Math.min((now - last) / 1000, 0.05);
        last = now;
        const cur = posRef.current!;
        const x = cur.x + dir * 90 * dt;
        if ((dir > 0 && x >= target) || (dir < 0 && x <= target)) {
          move({ x: target, y: cur.y });
          walkingRef.current = false;
          play(baseRef.current);
          return schedule();
        }
        move({ x, y: cur.y });
        raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    };
    schedule();
    return () => {
      clearTimeout(timer);
      cancelAnimationFrame(raf);
      walkingRef.current = false;
    };
  }, [reduced, mounted, move, play]);

  function clampToPage(p: Point): Point {
    const doc = document.documentElement;
    return { x: clamp(p.x, 0, doc.scrollWidth - cellW), y: clamp(p.y, 0, doc.scrollHeight - cellH) };
  }

  function onPointerDown(e: PointerEvent<HTMLButtonElement>) {
    if (e.button !== 0 || !posRef.current) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    walkingRef.current = false;
    dragRef.current = {
      startX: e.pageX,
      startY: e.pageY,
      offX: e.pageX - posRef.current.x,
      offY: e.pageY - posRef.current.y,
      lastX: e.pageX,
      moved: false,
    };
  }

  function onPointerMove(e: PointerEvent<HTMLButtonElement>) {
    const d = dragRef.current;
    if (!d) return;
    if (!d.moved) {
      if (Math.hypot(e.pageX - d.startX, e.pageY - d.startY) < 5) return;
      d.moved = true;
      draggingRef.current = true;
      freeRef.current = true;
      setDragging(true);
      setLook(null);
    }
    const dx = e.pageX - d.lastX;
    if (Math.abs(dx) > 1) {
      const want = dx > 0 ? rows.runRight : rows.runLeft;
      if (rowRef.current !== want) play(want);
      d.lastX = e.pageX;
    }
    move(clampToPage({ x: e.pageX - d.offX, y: e.pageY - d.offY }));
  }

  function onPointerUp(cancelled: boolean) {
    const d = dragRef.current;
    dragRef.current = null;
    if (!d) return;
    if (d.moved) {
      draggingRef.current = false;
      setDragging(false);
      play(rows.jumping);
      if (!droppedOnce.current) {
        droppedOnce.current = true;
        say({ title: "It stays where you leave it.", body: "Same as on your desktop.", ttl: 3500 });
      }
    } else if (!cancelled) {
      act("wave");
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLButtonElement>) {
    const step = e.shiftKey ? 96 : 24;
    const delta: Record<string, Point> = {
      ArrowLeft: { x: -step, y: 0 },
      ArrowRight: { x: step, y: 0 },
      ArrowUp: { x: 0, y: -step },
      ArrowDown: { x: 0, y: step },
    };
    const d = delta[e.key];
    if (!d || !posRef.current) return;
    e.preventDefault();
    freeRef.current = true;
    walkingRef.current = false;
    move(clampToPage({ x: posRef.current.x + d.x, y: posRef.current.y + d.y }));
  }

  const showLook = look !== null && row === rows.idle && !dragging;
  const cell = showLook
    ? cellPosition(lookRow + Math.floor(look / 8), look % 8)
    : cellPosition(row.index, reduced && !row.loops ? Math.floor(row.durations.length / 2) : frame);

  const live = mounted && pos !== null;
  const pageWidth = live ? document.documentElement.clientWidth : 0;
  // Beside Ghost like the app's bubbles: on his left when there is room, else on his right, else above him.
  const width = Math.min(bubbleWidth, pageWidth - 16);
  const side = !live ? "left" : pos.x - 8 >= width + 4 ? "left" : pageWidth - (pos.x + cellW) - 8 >= width + 4 ? "right" : "top";
  const bubbleStyle = !live
    ? {}
    : side === "left"
      ? { left: pos.x - width - 4, top: pos.y + cellH * 0.12, width }
      : side === "right"
        ? { left: pos.x + cellW + 4, top: pos.y + cellH * 0.12, width }
        : {
            left: clamp(pos.x + cellW / 2 - width / 2, 8, pageWidth - width - 8),
            top: pos.y,
            width,
            transform: "translateY(-100%)",
          };

  return (
    <div className="demo">
      <div className="desktop-wrap">
        <div className="desktop" aria-label="A demo desktop with an agent session and the pet">
          <div className="desktop-menubar" aria-hidden="true">
            <span className="desktop-app">Terminal</span>
            <span>Shell</span>
            <span>Edit</span>
            <span>View</span>
            <span className="desktop-clock">Fri 10:42</span>
          </div>
          <AgentWindow state={agent} />
        </div>
        <div className="desktop-anchor" ref={anchorRef}>
          {!live && <div className="sprite" style={{ backgroundPosition: cellPosition(0, 0) }} aria-hidden="true" />}
        </div>
      </div>

      <div className="acts" role="group" aria-label="Show what the pet does">
        <span className="acts-label">Try it</span>
        {acts.map(({ act: name, label }) => (
          <button key={name} type="button" className="chip" onClick={() => act(name)}>
            {label}
          </button>
        ))}
      </div>
      <p className="acts-hint">Drag the pet anywhere on the page. With the keyboard, Tab to it and use the arrow keys.</p>

      {live &&
        createPortal(
          <div className="pet-layer">
            <button
              type="button"
              className={`pet${dragging ? " is-dragging" : ""}`}
              style={{ left: pos.x, top: pos.y }}
              aria-label="The ironpet pet. Press to wave; arrow keys move it."
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={() => onPointerUp(false)}
              onPointerCancel={() => onPointerUp(true)}
              onClick={(e) => e.detail === 0 && act("wave")}
              onKeyDown={onKeyDown}
            >
              <span className="sprite" style={{ backgroundPosition: cell }} />
            </button>
            <div className="bubble-region" role="status" aria-live="polite">
              {bubble && (
                <div key={bubble.id} className={`bubble bubble-${side}`} style={bubbleStyle}>
                  <p className="bubble-title">{bubble.title}</p>
                  {bubble.body && <div className="bubble-body">{bubble.body}</div>}
                  {bubble.actions && (
                    <div className="bubble-actions">
                      {bubble.actions.map((a) => (
                        <button key={a.label} type="button" className={a.primary ? "primary" : undefined} onClick={a.run}>
                          {a.label}
                          {a.hint && <kbd>{a.hint}</kbd>}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>,
          document.body,
        )}
    </div>
  );
}

const transcript: Record<AgentState, { tone?: "muted" | "warn" | "ok" | "bad"; text: string }[]> = {
  idle: [{ tone: "muted", text: "Ready when you are." }],
  working: [
    { text: "⏺ Read src/auth/session.ts" },
    { text: "⏺ refreshToken() resolves after the test checks the session" },
    { tone: "muted", text: "⏺ Editing src/auth/login.ts…" },
  ],
  waiting: [
    { text: "⏺ Read src/auth/session.ts" },
    { text: "⏺ Edited src/auth/login.ts" },
    { tone: "warn", text: "⏺ Wants to run npm test -- login · waiting for approval" },
  ],
  done: [
    { text: "⏺ Edited src/auth/login.ts" },
    { tone: "ok", text: "⏺ npm test -- login · 20 passed, 20 runs in a row" },
    { text: "Done. login() now waits for the token refresh." },
  ],
  failed: [
    { text: "⏺ Pushed fix/login-refresh" },
    { tone: "bad", text: "⏺ CI · build failed on #84" },
  ],
};

function AgentWindow({ state }: { state: AgentState }) {
  return (
    <div className="agent-window" aria-hidden="true">
      <div className="agent-titlebar">
        <span className="lights">
          <i />
          <i />
          <i />
        </span>
        <span className="agent-title">demo-app — claude</span>
      </div>
      <div className="agent-body">
        <p className="agent-prompt">
          <span>&gt;</span> fix the flaky login test
        </p>
        {transcript[state].map((line) => (
          <p key={line.text} className={line.tone ? `tone-${line.tone}` : undefined}>
            {line.text}
          </p>
        ))}
      </div>
    </div>
  );
}
