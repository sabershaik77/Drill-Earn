# Drill & Earn — Edge Functions

## Folder
```
supabase/functions/
  _shared/lib.ts       Telegram initData check, session token, helpers
  _shared/layout.ts    map generator + round verification (client must use same genLayout)
  game/index.ts        player API
  ad-callback/index.ts ad network server callback
  admin/index.ts       admin panel API
```

## Deploy (Supabase CLI)
```bash
npm i -g supabase
supabase login
supabase init                      # run in your project folder
supabase link --project-ref YOUR_PROJECT_REF
# copy the `supabase/functions/*` folders from this zip into your project's supabase/functions/

supabase secrets set BOT_TOKEN=123456:ABC...        # from @BotFather
supabase secrets set SESSION_SECRET=$(openssl rand -hex 32)
supabase secrets set AD_CALLBACK_SECRET=$(openssl rand -hex 24)

supabase functions deploy game --no-verify-jwt
supabase functions deploy ad-callback --no-verify-jwt
supabase functions deploy admin
```
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically. Never put the service_role key in the game or admin front-end.

## Player API  (POST https://<ref>.supabase.co/functions/v1/game)
Header: `Authorization: Bearer <token>` (except `auth`)

| action | body | returns |
|---|---|---|
| auth | `{initData, device?}` (`Telegram.WebApp.initData`) | `{token, player}` |
| me | — | `{energy, wallet, token, withdrawals}` |
| start_round | — | `{round_id, seed, expires_at, energy_left}` |
| finish_round | `{round_id, duration_ms, events:[{i,t}]}` | `{ok, yellow, cash, blue, score}` |
| ad_start | `{network}` | `{session}` |
| swap | `{yellow}` | `{pxn, rate}` |
| withdraw | `{pxn, address}` | `{withdrawal_id, status}` |
| leaderboard | — | `{top}` |

Errors come back as `{error: "no_energy" | "ad_limit_reached" | "round_already_active" | ...}`.

## What the client must do (next step)
1. Call `start_round`, get `seed`.
2. Build the map with `genLayout(seed)` from `layout.ts` (same code, copied into the game) instead of `Math.random`; player start position/angle also come from it.
3. Record every pickup as `{i: itemIndex, t: gameTimeMs}` where `t` is the sum of frame `dt` (game time), not wall clock.
4. When HP reaches 0 send `finish_round` with all events and `duration_ms` (= game time at death).
The server recomputes score/cash/diamonds from events; totals sent by the client are ignored.

## Server checks in finish_round
- item index exists in the seeded layout, no duplicate pickups
- times are increasing and not beyond the round duration
- drill never moves faster than 90 px/s (+25% lag tolerance)
- round only counts if HP really reached 0 (10 stones) and ends right after the last event
- duration is not longer than real server time since `start_round`
- SQL then caps yellow per round / minute / day and flags + lowers trust score on violations

## Ad callback
Set the reward/postback URL in your ad network to:
`https://<ref>.supabase.co/functions/v1/ad-callback?secret=<AD_CALLBACK_SECRET>&session={session_id_macro}`
If the network only sends the Telegram user id, use `&userid={user_id_macro}` instead.
The player's energy is only added when this callback arrives, never from the client.

## Admin API  (POST https://<ref>.supabase.co/functions/v1/admin)
Header: `Authorization: Bearer <Supabase Auth access token of an admin_users row>`

| action | body |
|---|---|
| dashboard | — |
| read | `{table, select?, eq?:{col:val}, search?, order?, asc?, limit?, offset?}` |
| player | `{id}` (profile, wallet, flags, rounds, ledger, withdrawals) |
| review_withdrawal | `{id, op:"approve"|"reject"|"paid"|"failed", reason?, tx_hash?}` |
| ban | `{player_id, ban:true|false, reason}` |
| resolve_flag | `{id, status:"confirmed"|"dismissed"}` |
| set_rate | `{yellow_per_pxn}` (owner only) |
| crud | `{table, op:"upsert"|"delete", row | id}` for earn_tasks, rewards, drills, store_items, leaderboard_seasons, app_settings, token_config |

Roles: viewer = read only, support = ban/flags, admin = withdrawals + catalog edits, owner = settings + token rate.
Admin panel sections map to: players → `read players` / `player`, withdrawals → `read withdrawals`, anti-cheat → `read anticheat_flags` + `resolve_flag` + `ban`, audit log → `read audit_log`, token → `set_rate` + `crud token_config`, tasks/rewards/store/drills/leaderboard → `crud`, marketplace → `read marketplace_listings`.
