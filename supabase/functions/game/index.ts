import { clientIp, cors, json, playerFrom, rpc, sb, signSession, verifyInitData } from "../_shared/lib.ts";
import { NEUTRAL_STATS, sanitizeStats, verifyRound } from "../_shared/layout.ts";

// Deploy with: supabase functions deploy game --no-verify-jwt
const UUID = /^[0-9a-f-]{36}$/i;

// Shape returned by the SQL function get_loadout():
// { drill: {...}|null, attachments: [...], stats: { speed_mult, hp_bonus, damage_reduction } }
type Loadout = { drill: any | null; attachments: any[]; stats: Record<string, number> };

const loadoutOut = (lo: Loadout) => ({
  equipped_drill: lo.drill ?? null,
  equipped_attachments: lo.attachments ?? [],
  stats: sanitizeStats(lo.stats),
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json();
    const ip = clientIp(req);

    // ---- login ----
    if (body.action === "auth") {
      const u = await verifyInitData(String(body.initData ?? ""));
      const pl = await rpc("upsert_player_from_tg", {
        p_tg_id: u.id, p_username: u.username ?? null, p_first: u.first_name ?? null,
        p_lang: u.language_code ?? null, p_premium: !!u.is_premium,
        p_device: body.device ? String(body.device).slice(0, 128) : null, p_ip: ip,
      });
      if (pl.status === "banned") return json({ error: "banned" }, 403);
      return json({ token: await signSession(pl.id), player: { id: pl.id, username: pl.username } });
    }

    let pid: string;
    try { pid = await playerFrom(req); } catch { return json({ error: "unauthorized" }, 401); }

    switch (body.action) {
      case "me": {
        const [energy, token, wd, pl, wal, st, lo] = await Promise.all([
          rpc("get_energy", { p_player: pid }),
          sb.from("token_config").select("symbol,jetton_master,decimals").eq("id", 1).single(),
          sb.from("withdrawals").select("id,pxn_amount,status,reject_reason,tx_hash,created_at")
            .eq("player_id", pid).order("created_at", { ascending: false }).limit(10),
          sb.from("players").select("ton_wallet").eq("id", pid).single(),
          sb.from("player_wallets").select("*").eq("player_id", pid).maybeSingle(),
          sb.from("app_settings").select("key,value").in("key", ["ad_provider", "ad_block_id"]),
          rpc<Loadout>("get_loadout", { p_player: pid }),
        ]);
        const wallet = wal.data ?? { pxn: 0, cash: 0, blue: 0 };

        const cfg: Record<string, string> = {};
        for (const row of st.data ?? []) {
          let v = row.value;
          if (typeof v === "string") { v = v.trim(); if (v.length > 1 && v[0] === '"' && v.endsWith('"')) v = v.slice(1, -1); }
          cfg[row.key] = v == null ? "" : String(v);
        }
        const provider = (cfg.ad_provider || "none").toLowerCase();

        return json({
          energy, wallet, token: token.data, withdrawals: wd.data, player: pl.data,
          ad_provider: ["adsgram", "monetag"].includes(provider) ? provider : "none",
          ad_block_id: cfg.ad_block_id ?? "",
          ...loadoutOut(lo),          // equipped_drill, equipped_attachments, stats
        });
      }

      // ---- inventory: catalog + what this player owns ----
      case "get_inventory": {
        await rpc("get_loadout", { p_player: pid }); // also grants the default drill to brand-new players
        const [drills, attachments, pd, pa] = await Promise.all([
          sb.from("drills").select("id,name,description,rarity,speed_mult,hp_bonus,max_level,image_url").eq("is_active", true).order("id"),
          sb.from("attachments").select("id,name,description,slot,speed_mult,hp_bonus,damage_reduction,image_url").eq("is_active", true).order("id"),
          sb.from("player_drills").select("id,drill_id,level,equipped,acquired_at").eq("player_id", pid),
          sb.from("player_attachments").select("id,attachment_id,equipped,acquired_at").eq("player_id", pid),
        ]);
        for (const r of [drills, attachments, pd, pa]) if (r.error) throw new Error(r.error.message);
        return json({
          drills: drills.data, attachments: attachments.data,
          player_drills: pd.data, player_attachments: pa.data,
        });
      }

      // ---- equip / unequip. body: { type: 'drill'|'attachment', id: number, slot?: string, equip?: boolean } ----
      // id = catalog id (drills.id / attachments.id). Ownership is checked inside the SQL function.
      case "equip_item": {
        const type = String(body.type);
        const id = Number(body.id);
        if (!["drill", "attachment"].includes(type) || !Number.isInteger(id) || id <= 0) throw new Error("bad_item");
        const slot = body.slot == null ? null : String(body.slot);
        if (slot !== null && !["front", "side", "back"].includes(slot)) throw new Error("slot_mismatch");
        const lo = await rpc<Loadout>("equip_item", {
          p_player: pid, p_type: type, p_id: id, p_slot: slot, p_equip: body.equip !== false,
        });
        return json({ ok: true, ...loadoutOut(lo) });
      }

      case "start_round": {
        const rows = await rpc<any[]>("start_round", { p_player: pid, p_ip: ip });
        const r = rows[0];

        // Snapshot the equipped setup for THIS round. finish_round verifies against this snapshot,
        // so swapping items after the round has started can never raise the allowed speed/HP.
        let lo: Loadout = { drill: null, attachments: [], stats: { ...NEUTRAL_STATS } };
        try {
          const cur = await rpc<Loadout>("get_loadout", { p_player: pid });
          const snap = { drill: cur.drill ?? null, attachments: cur.attachments ?? [], stats: sanitizeStats(cur.stats) };
          const { error } = await sb.from("rounds").update({ loadout: snap }).eq("id", r.o_round_id);
          if (!error) lo = snap; // if the snapshot could not be stored, play (and verify) with neutral stats
        } catch (_) { /* neutral loadout */ }

        return json({
          round_id: r.o_round_id, seed: Number(r.o_seed), expires_at: r.o_expires_at, energy_left: r.o_energy_left,
          loadout: { ...lo.stats, drill: lo.drill, attachments: lo.attachments },
        });
      }

      case "finish_round": {
        if (!UUID.test(String(body.round_id))) throw new Error("bad_round");
        const { data: r } = await sb.from("rounds").select("id,player_id,seed,loadout").eq("id", body.round_id).single();
        if (!r || r.player_id !== pid) throw new Error("round_not_found");
        const duration = Math.floor(Number(body.duration_ms));
        const stats = sanitizeStats(r.loadout?.stats ?? NEUTRAL_STATS);
        const v = verifyRound(Number(r.seed), body.events, duration, stats);

        const res = await rpc("finish_round", {
          p_round: r.id, p_accepted: v.ok, p_score: v.score, p_cash: v.cash, p_blue: v.blue,
          p_pxn: v.pxn, p_duration_ms: Number.isFinite(duration) ? duration : 0,
          p_events: Array.isArray(body.events) ? body.events.length : 0,
          p_verdict: v.ok ? {} : { reason: v.reason },
        });
        return json(res);
      }

      case "ad_start": {
        const id = await rpc("ad_start", { p_player: pid, p_network: String(body.network ?? "adsgram").slice(0, 32) });
        return json({ session: id });
      }

      case "withdraw": {
        const pxn = Number(body.pxn);
        if (!(pxn > 0)) throw new Error("bad_amount");
        const id = await rpc("request_withdrawal", { p_player: pid, p_pxn: pxn, p_address: String(body.address ?? "") });
        return json({ withdrawal_id: id, status: "pending" });
      }

      case "leaderboard": {
        const [lb, season] = await Promise.all([
          sb.from("leaderboard_current")
            .select("rank,player_id,username,first_name,score,pxn").order("rank").limit(50),
          sb.from("leaderboard_seasons").select("prize_pool").eq("status", "active")
            .order("starts_at", { ascending: false }).limit(1).maybeSingle(),
        ]);
        return json({ top: lb.data ?? [], prizes: season.data?.prize_pool ?? [] });
      }

      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
