// THIS FILE IS THE CONTRACT between game client and server.
// The client must generate the map with the exact same genLayout() code.

export const WS = 3840;          // world size in px (640 * 6)
export const N_ITEMS = 4200;
export const PICK_R = 26;        // pickup radius
export const MAX_SPEED = 90;     // px/s
export const SPEED_TOL = 1.25;   // lag tolerance
export const HP = 100;
export const STONE_DMG = 10;

export type ItemType = "gold" | "score" | "cash" | "sky" | "stone";
export type Item = { i: number; x: number; y: number; t: ItemType };

export function mulberry32(a: number) {
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function genLayout(seed: number) {
  const r = mulberry32(seed);
  const start = { x: 400 + r() * (WS - 800), y: 400 + r() * (WS - 800), a: r() * 6.28 };
  const items = new Map<number, Item>();
  for (let n = 0; n < N_ITEMS; n++) {
    // always consume 4 random numbers per slot so indexes stay in sync
    const x = 40 + r() * (WS - 80);
    const y = 40 + r() * (WS - 80);
    const q = r();
    r(); // rotation (visual only)
    if (Math.hypot(x - start.x, y - start.y) < 90) continue;
    const t: ItemType = q < .02 ? "gold" : q < .12 ? "score" : q < .32 ? "cash" : q < .52 ? "sky" : "stone";
    items.set(n, { i: n, x, y, t });
  }
  return { start, items };
}

type Verdict = { ok: boolean; reason?: string; score: number; cash: number; blue: number; yellow: number };

// events = [{ i: itemIndex, t: gameTimeMs }, ...] in pickup order.
// Rewards are recomputed here; client-sent totals are never trusted.
export function verifyRound(seed: number, events: unknown, durationMs: number): Verdict {
  const bad = (reason: string): Verdict => ({ ok: false, reason, score: 0, cash: 0, blue: 0, yellow: 0 });
  if (!Array.isArray(events) || events.length > N_ITEMS) return bad("bad_events");
  if (!Number.isFinite(durationMs) || durationMs <= 0) return bad("bad_duration");

  const { start, items } = genLayout(seed);
  const speed = MAX_SPEED * SPEED_TOL;
  let px = start.x, py = start.y, pt = 0, hp = HP;
  let score = 0, cash = 0, blue = 0, yellow = 0;
  const seen = new Set<number>();

  for (let k = 0; k < events.length; k++) {
    const e = events[k] as { i?: unknown; t?: unknown };
    if (!e || !Number.isInteger(e.i) || typeof e.t !== "number" || !Number.isFinite(e.t)) return bad("bad_event");
    if (hp <= 0) return bad("event_after_death");
    const it = items.get(e.i as number);
    if (!it || seen.has(it.i)) return bad("bad_item");
    if (e.t < pt || e.t > durationMs) return bad("bad_time");

    // drill cannot travel faster than MAX_SPEED (pickup radius gives some slack)
    const dt = (e.t - pt) / 1000;
    const slack = (k === 0 ? PICK_R : 2 * PICK_R) + 4;
    if (Math.hypot(it.x - px, it.y - py) > speed * dt + slack) return bad("too_fast");

    seen.add(it.i); px = it.x; py = it.y; pt = e.t;
    if (it.t === "stone") hp -= STONE_DMG;
    else if (it.t === "cash") cash += 1;
    else if (it.t === "score") score += 5;
    else if (it.t === "sky") { blue += 1; score += 30; }
    else { yellow += 1; score += 100; }
  }

  if (hp > 0) return bad("round_not_finished");        // a round only ends when HP hits 0
  if (durationMs - pt > 2000) return bad("late_finish"); // stops duration inflation
  return { ok: true, score, cash, blue, yellow };
}
