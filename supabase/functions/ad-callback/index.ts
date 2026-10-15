import { safeEq, sb } from "../_shared/lib.ts";

// Deploy with: supabase functions deploy ad-callback --no-verify-jwt
// Ad network calls (server-to-server) after a COMPLETED ad:
//   https://<project>.supabase.co/functions/v1/ad-callback?secret=<AD_CALLBACK_SECRET>&session=<id>
// If the network only sends the Telegram user id (e.g. Adsgram `userid`), pass &userid=... and
// the latest open ad session of that player is completed instead.

Deno.serve(async (req) => {
  const url = new URL(req.url);
  let p: Record<string, string> = Object.fromEntries(url.searchParams);
  if (req.method === "POST") {
    try { p = { ...p, ...(await req.json()) }; } catch { /* ignore */ }
  }
  if (!safeEq(String(p.secret ?? ""), Deno.env.get("AD_CALLBACK_SECRET") ?? "")) {
    return new Response("forbidden", { status: 403 });
  }

  let session = String(p.session ?? p.ymid ?? "");
  if (!session && p.userid) {
    const { data: pl } = await sb.from("players").select("id").eq("tg_id", Number(p.userid)).maybeSingle();
    if (pl) {
      const { data: s } = await sb.from("ad_sessions").select("id").eq("player_id", pl.id)
        .eq("status", "started").order("started_at", { ascending: false }).limit(1).maybeSingle();
      session = s?.id ?? "";
    }
  }
  if (!/^[0-9a-f-]{36}$/i.test(session)) return new Response("bad session", { status: 400 });

  const { error } = await sb.rpc("ad_complete", { p_session: session });
  if (error) return new Response(error.message, { status: 400 });
  return new Response("ok");
});
