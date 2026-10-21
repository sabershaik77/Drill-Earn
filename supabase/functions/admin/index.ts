import { clientIp, cors, json, rpc, sb } from "../_shared/lib.ts";

// Deploy with: supabase functions deploy admin   (JWT verification stays ON)
// Admin logs in with Supabase Auth (email + password, enable MFA), sends the access token as Bearer.
// Every write is role-checked here AND inside the SQL functions, and written to audit_log.

const RANK: Record<string, number> = { viewer: 0, support: 1, admin: 2, owner: 3 };

const READ = new Set([
  "players", "rounds", "ledger", "withdrawals", "swaps", "anticheat_flags", "bans", "audit_log",
  "ad_sessions", "marketplace_listings", "player_drills", "attachments", "task_completions", "reward_claims",
  "leaderboard_scores", "store_purchases", "token_rate_history", "earn_tasks", "rewards", "drills",
  "store_items", "leaderboard_seasons", "app_settings", "token_config", "admin_users",
]);
// tables the panel may create/edit/delete rows in (value = primary key column)
const CRUD: Record<string, string> = {
  earn_tasks: "id", rewards: "id", drills: "id", attachments: "id", store_items: "id",
  leaderboard_seasons: "id", app_settings: "key", token_config: "id",
};
const NO_DELETE = new Set(["app_settings", "token_config"]);
const COL = /^[a-z_]+$/;
const SELECT = /^[a-z_,*()\s]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
    const { data: { user }, error: uerr } = await sb.auth.getUser(token);
    if (uerr || !user) return json({ error: "unauthorized" }, 401);
    const { data: adm } = await sb.from("admin_users").select("role,is_active").eq("user_id", user.id).maybeSingle();
    if (!adm?.is_active) return json({ error: "forbidden" }, 403);

    const me = user.id, ip = clientIp(req), rank = RANK[adm.role] ?? 0;
    const need = (min: keyof typeof RANK) => { if (rank < RANK[min]) throw new Error("forbidden"); };
    const audit = (action: string, entity: string, id: string, before: unknown, after: unknown) =>
      rpc("write_audit", {
        p_type: "admin", p_actor: me, p_action: action, p_entity: entity,
        p_entity_id: id, p_before: before ?? null, p_after: after ?? null, p_ip: ip,
      });

    const body = await req.json();
    switch (body.action) {
      case "dashboard": {
        const { data } = await sb.from("admin_dashboard").select("*").single();
        return json(data);
      }

      // generic filtered read: { table, select?, eq?: {col: val}, order?, asc?, limit?, offset? }
      case "read": {
        const t = String(body.table);
        if (!READ.has(t)) throw new Error("bad_table");
        const sel = body.select ? String(body.select) : "*";
        if (!SELECT.test(sel)) throw new Error("bad_select");
        let q = sb.from(t).select(sel, { count: "exact" });
        for (const [c, v] of Object.entries(body.eq ?? {})) {
          if (!COL.test(c)) throw new Error("bad_filter");
          q = q.eq(c, v as string);
        }
        if (body.search && t === "players") q = q.or(`username.ilike.%${String(body.search).replace(/[%,()]/g, "")}%,first_name.ilike.%${String(body.search).replace(/[%,()]/g, "")}%`);
        if (body.order && COL.test(String(body.order))) q = q.order(String(body.order), { ascending: !!body.asc });
        const limit = Math.min(Number(body.limit) || 50, 200);
        const off = Math.max(Number(body.offset) || 0, 0);
        const { data, count, error } = await q.range(off, off + limit - 1);
        if (error) throw new Error(error.message);
        return json({ rows: data, total: count });
      }

      case "player": {
        const id = String(body.id);
        const [pl, fl, rd, lg, wd] = await Promise.all([
          sb.from("players").select("*, player_wallets(*), player_devices(*)").eq("id", id).single(),
          sb.from("anticheat_flags").select("*").eq("player_id", id).order("created_at", { ascending: false }).limit(50),
          sb.from("rounds").select("*").eq("player_id", id).order("started_at", { ascending: false }).limit(30),
          sb.from("ledger").select("*").eq("player_id", id).order("created_at", { ascending: false }).limit(50),
          sb.from("withdrawals").select("*").eq("player_id", id).order("created_at", { ascending: false }).limit(20),
        ]);
        return json({ player: pl.data, flags: fl.data, rounds: rd.data, ledger: lg.data, withdrawals: wd.data });
      }

      case "review_withdrawal": { // approve | reject | paid | failed
        need("admin");
        return json(await rpc("admin_review_withdrawal", {
          p_admin: me, p_id: body.id, p_action: body.op, p_reason: body.reason ?? null, p_tx: body.tx_hash ?? null, p_ip: ip,
        }));
      }

      case "ban": {
        need("support");
        await rpc("admin_ban_player", { p_admin: me, p_player: body.player_id, p_ban: !!body.ban, p_reason: String(body.reason ?? ""), p_ip: ip });
        return json({ ok: true });
      }

      case "resolve_flag": { // confirmed | dismissed
        need("support");
        if (!["confirmed", "dismissed"].includes(body.status)) throw new Error("bad_status");
        const { data, error } = await sb.from("anticheat_flags")
          .update({ status: body.status, reviewed_by: me }).eq("id", body.id).select().single();
        if (error) throw new Error(error.message);
        await audit("resolve_flag_" + body.status, "anticheat_flag", String(body.id), null, data);
        return json({ ok: true });
      }

      case "grant_item": {
        need("admin");
        const type = String(body.type);
        const id = Number(body.item_id);
        const player_id = String(body.player_id);
        if (!player_id || !type || !id) throw new Error("bad_request");
        
        if (type === 'store') {
          const res = await rpc("admin_grant_store_item", { p_admin: me, p_player: player_id, p_store_item: id, p_ip: ip });
          return json(res);
        } else {
          const res = await rpc("admin_grant_item", { p_admin: me, p_player: player_id, p_type: type, p_item: id, p_ip: ip });
          return json(res);
        }
      }

      case "set_rate": {
        need("owner");
        await rpc("admin_set_rate", { p_admin: me, p_yellow_per_pxn: Number(body.yellow_per_pxn), p_ip: ip });
        return json({ ok: true });
      }

      // create / update / delete rows for catalog sections
      case "crud": {
        const t = String(body.table), pk = CRUD[t];
        if (!pk) throw new Error("bad_table");
        need(t === "app_settings" ? "owner" : "admin");
        if (body.op === "delete") {
          if (NO_DELETE.has(t)) throw new Error("not_allowed");
          const { data: before } = await sb.from(t).select("*").eq(pk, body.id).maybeSingle();
          const { error } = await sb.from(t).delete().eq(pk, body.id);
          if (error) throw new Error(error.message);
          await audit("delete", t, String(body.id), before, null);
          return json({ ok: true });
        }
        if (body.op === "upsert") {
          const row = { ...(body.row ?? {}) };
          if (t === "token_config") { delete row.yellow_per_pxn; row.id = 1; } // rate only via set_rate
          if (t === "app_settings") row.updated_at = new Date().toISOString();
          const id = row[pk];
          const { data: before } = id !== undefined
            ? await sb.from(t).select("*").eq(pk, id).maybeSingle() : { data: null };
          const { data, error } = await sb.from(t).upsert(row).select().single();
          if (error) throw new Error(error.message);
          await audit(before ? "update" : "create", t, String(data[pk]), before, data);
          return json({ row: data });
        }
        throw new Error("bad_op");
      }

      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    const m = String((e as Error).message ?? e);
    return json({ error: m }, m === "forbidden" ? 403 : 400);
  }
});
