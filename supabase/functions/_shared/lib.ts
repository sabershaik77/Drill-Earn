import { createClient } from "npm:@supabase/supabase-js@2";
import { jwtVerify, SignJWT } from "npm:jose@5";

// service_role client: only ever used inside Edge Functions, never in the browser
export const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const enc = new TextEncoder();
const BOT_TOKEN = Deno.env.get("BOT_TOKEN") ?? "";
const SESSION_KEY = enc.encode(Deno.env.get("SESSION_SECRET") ?? "");

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

export function clientIp(req: Request): string | null {
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "";
  return /^[0-9a-fA-F:.]+$/.test(ip) ? ip : null;
}

export function safeEq(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

const hex = (u: Uint8Array) => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

async function hmac(key: Uint8Array, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(data)));
}

// Telegram Mini App initData verification (official algorithm)
export async function verifyInitData(initData: string) {
  if (!BOT_TOKEN) throw new Error("server_misconfigured");
  const p = new URLSearchParams(initData);
  const hash = p.get("hash");
  if (!hash) throw new Error("bad_init_data");
  p.delete("hash");
  const dcs = [...p.entries()].map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const secret = await hmac(enc.encode("WebAppData"), BOT_TOKEN);
  if (!safeEq(hex(await hmac(secret, dcs)), hash)) throw new Error("bad_init_data");
  const age = Date.now() / 1000 - Number(p.get("auth_date") ?? 0);
  if (!(age >= 0 && age < 3600)) throw new Error("init_data_expired");
  const user = JSON.parse(p.get("user") ?? "null");
  if (!user?.id) throw new Error("bad_init_data");
  return user as { id: number; username?: string; first_name?: string; language_code?: string; is_premium?: boolean };
}

export const signSession = (playerId: string) =>
  new SignJWT({}).setProtectedHeader({ alg: "HS256" }).setSubject(playerId)
    .setIssuedAt().setExpirationTime("12h").sign(SESSION_KEY);

export async function playerFrom(req: Request): Promise<string> {
  const t = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
  const { payload } = await jwtVerify(t, SESSION_KEY);
  if (!payload.sub) throw new Error("unauthorized");
  return payload.sub;
}

export async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
