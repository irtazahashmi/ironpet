// The Codex v2 atlas that tools/make_pet.swift draws: 8 columns of 192x208 cells. Rows and timings match
// Sources/IronPetKit/Atlas.swift, so Ghost moves on the site exactly as he does in the app.

export type Row = { index: number; durations: number[]; loops: boolean };

function uniform(index: number, frames: number, each: number, last: number, loops = true): Row {
  return { index, durations: [...Array<number>(frames - 1).fill(each), last], loops };
}

export const rows = {
  idle: { index: 0, durations: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32], loops: true },
  runRight: uniform(1, 8, 0.12, 0.22),
  runLeft: uniform(2, 8, 0.12, 0.22),
  waving: uniform(3, 4, 0.14, 0.28, false),
  jumping: uniform(4, 5, 0.14, 0.28, false),
  failed: uniform(5, 8, 0.14, 0.24),
  waiting: uniform(6, 6, 0.15, 0.26),
  working: uniform(7, 6, 0.12, 0.22),
  review: uniform(8, 6, 0.15, 0.28),
  drinking: { index: 11, durations: [0.3, 0.3, 0.55, 0.55, 0.35, 0.9], loops: false },
  stretching: { index: 12, durations: [0.25, 0.25, 0.45, 0.45, 0.5, 0.5, 0.3, 0.6], loops: false },
} satisfies Record<string, Row>;

/** Rows 9 and 10 hold 16 look directions, clockwise from straight up. */
export const lookRow = 9;

export const scale = 0.625;
export const cellW = 192 * scale;
export const cellH = 208 * scale;
export const sheet = { src: "/pet/ghost.webp", width: 1536 * scale, height: 2704 * scale };

/** The look cell (0-15) for a pointer at (dx, dy) from Ghost's face, in screen coordinates. */
export function lookIndex(dx: number, dy: number) {
  const angle = Math.atan2(dx, -dy); // 0 is up, clockwise
  return (Math.round(angle / ((22.5 * Math.PI) / 180)) + 16) % 16;
}

export function cellPosition(row: number, col: number) {
  return `${-col * cellW}px ${-row * cellH}px`;
}
