import { clientIp, cors, json, playerFrom, rpc, sb, signSession, verifyInitData } from "../_shared/lib.ts";
import { verifyRound } from "../_shared/layout.ts";

// Deploy with: supabase functions deploy game --no-verify-jwt
// (auth is our own session token issued after Telegram initData verification)

const UUID = /^[0-9a-f-]{36}$/i;

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
        const [energy, wallet, token, wd] = await Promise.all([
          rpc("get_energy", { p_player: pid }),
          sb.from("player_wallets").select("yellow,cash,blue,pxn").eq("player_id", pid).single(),
          sb.from("token_config").select("symbol,yellow_per_pxn,swap_fee_bps,min_swap_yellow,swap_enabled").eq("id", 1).single(),
          sb.from("withdrawals").select("id,pxn_amount,status,reject_reason,tx_hash,created_at")
            .eq("player_id", pid).order("created_at", { ascending: false }).limit(10),
        ]);
        return json({ energy, wallet: wallet.data, token: token.data, withdrawals: wd.data });
      }

      case "start_round": {
        const rows = await rpc<any[]>("start_round", { p_player: pid, p_ip: ip });
        const r = rows[0];
        return json({ round_id: r.o_round_id, seed: Number(r.o_seed), expires_at: r.o_expires_at, energy_left: r.o_energy_left });
      }

      case "finish_round": {
        if (!UUID.test(String(body.round_id))) throw new Error("bad_round");
        const { data: r } = await sb.from("rounds").select("id,player_id,seed").eq("id", body.round_id).single();
        if (!r || r.player_id !== pid) throw new Error("round_not_found");
        const duration = Math.floor(Number(body.duration_ms));
        const v = verifyRound(Number(r.seed), body.events, duration);
        const res = await rpc("finish_round", {
          p_round: r.id, p_accepted: v.ok, p_score: v.score, p_cash: v.cash, p_blue: v.blue,
          p_yellow: v.yellow, p_duration_ms: Number.isFinite(duration) ? duration : 0,
          p_events: Array.isArray(body.events) ? body.events.length : 0,
          p_verdict: v.ok ? {} : { reason: v.reason },
        });
        return json(res);
      }

      case "ad_start": {
        const id = await rpc("ad_start", { p_player: pid, p_network: String(body.network ?? "adsgram").slice(0, 32) });
        return json({ session: id }); // pass this to the ad SDK as the custom/user param
      }

      case "swap": {
        const y = Number(body.yellow);
        if (!Number.isInteger(y) || y <= 0) throw new Error("bad_amount");
        return json(await rpc("swap_yellow_to_pxn", { p_player: pid, p_yellow: y }));
      }

      case "withdraw": {
        const pxn = Number(body.pxn);
        if (!(pxn > 0)) throw new Error("bad_amount");
        const id = await rpc("request_withdrawal", { p_player: pid, p_pxn: pxn, p_address: String(body.address ?? "") });
        return json({ withdrawal_id: id, status: "pending" });
      }

      case "leaderboard": {
        const { data } = await sb.from("leaderboard_current")
          .select("rank,player_id,username,first_name,score,yellow").order("rank").limit(50);
        return json({ top: data });
      }

      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
