// CONTRACT between game client and server. genLayout() must match exactly.

export const WS = 3840;
export const N_ITEMS = 4200;
export const PICK_R = 26;
export const MAX_SPEED = 90;      // base drill speed (px/s). Real limit = MAX_SPEED * speed_mult
export const SPEED_TOL = 1.25;
export const HP = 100;            // base HP. Real start HP = HP + hp_bonus
export const STONE_DMG = 10;      // base stone damage. Real damage = STONE_DMG * (1 - damage_reduction)

export type ItemType = "pxn" | "score" | "cash" | "sky" | "stone";
export type Item = { i: number; x: number; y: number; t: ItemType };

// Stats of the loadout that was equipped when the round STARTED (snapshot stored in rounds.loadout).
export type PlayerStats = { speed_mult: number; hp_bonus: number; damage_reduction: number };
export const NEUTRAL_STATS: PlayerStats = { speed_mult: 1, hp_bonus: 0, damage_reduction: 0 };

// Defensive parsing: never trust shapes coming from JSON, and keep values in sane bounds.
export function sanitizeStats(s: unknown): PlayerStats {
  const o = (s && typeof s === "object" ? s : {}) as Record<string, unknown>;
  const num = (v: unknown, d: number) => (typeof v === "number" && Number.isFinite(v) ? v : d);
  return {
    speed_mult: Math.min(5, Math.max(0.1, num(o.speed_mult, 1))),
    hp_bonus: Math.min(1000, Math.max(-50, Math.trunc(num(o.hp_bonus, 0)))),
    damage_reduction: Math.min(0.9, Math.max(0, num(o.damage_reduction, 0))),
  };
}

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
    const x = 40 + r() * (WS - 80);
    const y = 40 + r() * (WS - 80);
    const q = r();
    r(); // rotation (visual only)
    if (Math.hypot(x - start.x, y - start.y) < 90) continue;
    const t: ItemType = q < .02 ? "pxn" : q < .12 ? "score" : q < .32 ? "cash" : q < .52 ? "sky" : "stone";
    items.set(n, { i: n, x, y, t });
  }
  return { start, items };
}

type Verdict = { ok: boolean; reason?: string; score: number; cash: number; blue: number; pxn: number };

export function verifyRound(
  seed: number,
  events: unknown,
  durationMs: number,
  playerStats: Partial<PlayerStats> | null = NEUTRAL_STATS,
): Verdict {
  const bad = (reason: string): Verdict => ({ ok: false, reason, score: 0, cash: 0, blue: 0, pxn: 0 });
  if (!Array.isArray(events) || events.length > N_ITEMS) return bad("bad_events");
  if (!Number.isFinite(durationMs) || durationMs <= 0) return bad("bad_duration");

  const ps = sanitizeStats(playerStats);
  const actualMaxSpeed = MAX_SPEED * ps.speed_mult;        // px/s the drill can really travel
  const speed = actualMaxSpeed * SPEED_TOL;                // + lag tolerance
  const startHp = HP + ps.hp_bonus;
  const stoneDmg = STONE_DMG * (1 - ps.damage_reduction);  // must be computed exactly like the client

  const { start, items } = genLayout(seed);
  let px = start.x, py = start.y, pt = 0, hp = startHp;
  let score = 0, cash = 0, blue = 0, pxn = 0;
  const seen = new Set<number>();

  for (let k = 0; k < events.length; k++) {
    const e = events[k] as { i?: unknown; t?: unknown };
    if (!e || !Number.isInteger(e.i) || typeof e.t !== "number" || !Number.isFinite(e.t)) return bad("bad_event");
    if (hp <= 0) return bad("event_after_death");
    const it = items.get(e.i as number);
    if (!it || seen.has(it.i)) return bad("bad_item");
    if (e.t < pt || e.t > durationMs) return bad("bad_time");

    const dt = (e.t - pt) / 1000;
    const slack = (k === 0 ? PICK_R : 2 * PICK_R) + 4;
    if (Math.hypot(it.x - px, it.y - py) > speed * dt + slack) return bad("too_fast");

    seen.add(it.i); px = it.x; py = it.y; pt = e.t;
    if (it.t === "stone") hp -= stoneDmg;
    else if (it.t === "cash") cash += 1;       // +1 cash, no score
    else if (it.t === "score") score += 5;     // only the white cross gives score
    else if (it.t === "sky") blue += 1;
    else pxn += 1; // "pxn": +1 PXN, no score
  }

  if (hp > 0) return bad("round_not_finished");
  if (durationMs - pt > 2000) return bad("late_finish");
  return { ok: true, score, cash, blue, pxn };
}
