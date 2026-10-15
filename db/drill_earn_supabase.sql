-- =====================================================================
-- Drill & Earn — Supabase schema (Postgres)
-- Design rule: clients NEVER write to the DB. Telegram initData is verified
-- in an Edge Function, which calls the service_role-only RPCs below.
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

create type ledger_currency as enum ('yellow','cash','blue','pxn');

-- ---------------------------------------------------------------------
-- 1. SETTINGS (all tunable limits live here, editable from admin panel)
-- ---------------------------------------------------------------------
create table app_settings (
  key text primary key,
  value jsonb not null,
  description text,
  updated_at timestamptz not null default now()
);

insert into app_settings(key, value, description) values
 ('energy_cap','24','Max regenerating energy'),
 ('energy_regen_seconds','3600','1 energy per this many seconds'),
 ('energy_per_round','1','Energy used per round'),
 ('ads_per_day','10','Max rewarded ads per UTC day'),
 ('ad_cooldown_seconds','20','Min gap between two ads'),
 ('ad_min_watch_seconds','5','Ad callback earlier than this is rejected'),
 ('round_min_seconds','5','Shorter rounds are rejected'),
 ('round_max_seconds','300','Round expires after this'),
 ('max_yellow_per_round','8','Hard cap, tune from real play data'),
 ('max_yellow_per_minute','6','Round cap also scales with duration'),
 ('max_yellow_per_day','60','Per player per UTC day'),
 ('max_speed_px_s','90','Drill speed used by server verification'),
 ('speed_tolerance','1.25','Allowed multiplier for lag'),
 ('trust_flag_below','50','Player auto-flagged under this trust score'),
 ('withdraw_enabled','true',null),
 ('withdraw_min_pxn','10',null),
 ('withdraw_max_pxn','1000',null),
 ('withdraw_daily_cap_pxn','1000',null),
 ('withdraw_min_account_age_hours','72',null),
 ('withdraw_min_trust','70',null),
 ('marketplace_fee_bps','500','5% fee');

create or replace function cfg(k text) returns jsonb language sql stable as
$$ select value from app_settings where key = k $$;
create or replace function cfg_int(k text) returns bigint language sql stable as
$$ select (value #>> '{}')::bigint from app_settings where key = k $$;
create or replace function cfg_num(k text) returns numeric language sql stable as
$$ select (value #>> '{}')::numeric from app_settings where key = k $$;

-- ---------------------------------------------------------------------
-- 2. PLAYERS, WALLETS, DEVICES
-- ---------------------------------------------------------------------
create table players (
  id uuid primary key default gen_random_uuid(),
  tg_id bigint not null unique,
  username text,
  first_name text,
  language_code text,
  is_premium boolean not null default false,
  ton_wallet text,
  energy int not null default 24 check (energy >= 0),
  energy_updated_at timestamptz not null default now(),
  status text not null default 'active' check (status in ('active','flagged','banned')),
  trust_score int not null default 100 check (trust_score between 0 and 100),
  referred_by uuid references players(id),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index on players(status);
create index on players(last_seen_at);

create table player_wallets (
  player_id uuid primary key references players(id) on delete cascade,
  yellow bigint not null default 0 check (yellow >= 0),
  cash bigint not null default 0 check (cash >= 0),
  blue bigint not null default 0 check (blue >= 0),
  pxn numeric(30,9) not null default 0 check (pxn >= 0),
  lifetime_yellow bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table player_devices (
  player_id uuid references players(id) on delete cascade,
  device_hash text not null,
  ip inet,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (player_id, device_hash)
);
create index on player_devices(device_hash);

-- append-only money ledger: every balance change is recorded
create table ledger (
  id bigint generated always as identity primary key,
  player_id uuid not null references players(id),
  currency ledger_currency not null,
  amount numeric(30,9) not null,
  balance_after numeric(30,9) not null,
  kind text not null,          -- round_reward, ad, swap_out, swap_in, withdraw_hold, withdraw_refund, task, reward, store, market, admin_adjust
  ref_type text,
  ref_id uuid,
  meta jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index on ledger(player_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3. ROUNDS, ADS
-- ---------------------------------------------------------------------
create table rounds (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  seed bigint not null,                -- server seed: map layout is derived from it
  status text not null default 'active' check (status in ('active','finished','rejected','expired')),
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  finished_at timestamptz,
  duration_ms int,
  score bigint not null default 0,
  cash bigint not null default 0,
  blue bigint not null default 0,
  yellow bigint not null default 0,
  events_count int not null default 0,
  verdict jsonb not null default '{}',
  ip inet
);
create unique index one_active_round on rounds(player_id) where status = 'active';
create index on rounds(player_id, started_at desc);

create table ad_sessions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  network text not null,
  status text not null default 'started' check (status in ('started','completed','rejected')),
  day date not null default (now() at time zone 'utc')::date,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);
create index on ad_sessions(player_id, day);

-- ---------------------------------------------------------------------
-- 4. TOKEN (PXN), SWAPS, WITHDRAWALS
-- ---------------------------------------------------------------------
create table token_config (
  id int primary key default 1 check (id = 1),
  symbol text not null default 'PXN',
  network text not null default 'TON',
  jetton_master text,
  decimals int not null default 9,
  yellow_per_pxn numeric(20,6) not null default 1000 check (yellow_per_pxn > 0),
  swap_fee_bps int not null default 0,
  min_swap_yellow bigint not null default 1000,
  swap_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into token_config default values;

create table token_rate_history (
  id bigint generated always as identity primary key,
  yellow_per_pxn numeric(20,6) not null,
  changed_by uuid,
  created_at timestamptz not null default now()
);

create table swaps (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  yellow_in bigint not null,
  pxn_out numeric(30,9) not null,
  fee_pxn numeric(30,9) not null default 0,
  rate numeric(20,6) not null,
  created_at timestamptz not null default now()
);

create table withdrawals (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  pxn_amount numeric(30,9) not null check (pxn_amount > 0),
  to_address text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','paid','failed')),
  risk_score int not null default 0,
  reject_reason text,
  tx_hash text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index one_pending_withdrawal on withdrawals(player_id) where status = 'pending';
create index on withdrawals(status, created_at);

-- ---------------------------------------------------------------------
-- 5. DRILLS, STORE, MARKETPLACE
-- ---------------------------------------------------------------------
create table drills (
  id serial primary key,
  name text not null,
  description text,
  rarity text not null default 'common' check (rarity in ('common','rare','epic','legendary')),
  speed_mult numeric(4,2) not null default 1,
  hp_bonus int not null default 0,
  yellow_cap_bonus int not null default 0,
  max_level int not null default 1,
  image_url text,
  tradable boolean not null default true,
  is_active boolean not null default true
);

create table player_drills (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  drill_id int not null references drills(id),
  level int not null default 1,
  equipped boolean not null default false,
  acquired_at timestamptz not null default now()
);
create index on player_drills(player_id);
create unique index one_equipped_drill on player_drills(player_id) where equipped;

create table store_items (
  id serial primary key,
  sku text not null unique,
  name text not null,
  item_type text not null check (item_type in ('drill','energy_pack','boost')),
  price_currency ledger_currency not null,
  price_amount numeric(30,9) not null check (price_amount >= 0),
  payload jsonb not null default '{}',    -- e.g. {"drill_id":2} or {"energy":5}
  stock int,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz
);

create table store_purchases (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  item_id int not null references store_items(id),
  price_paid numeric(30,9) not null,
  created_at timestamptz not null default now()
);

create table marketplace_listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references players(id),
  player_drill_id uuid not null references player_drills(id),
  price_currency ledger_currency not null default 'yellow',
  price bigint not null check (price > 0),
  status text not null default 'active' check (status in ('active','sold','cancelled')),
  buyer_id uuid references players(id),
  fee bigint,
  created_at timestamptz not null default now(),
  sold_at timestamptz
);
create unique index one_active_listing on marketplace_listings(player_drill_id) where status = 'active';

-- ---------------------------------------------------------------------
-- 6. EARN TASKS, REWARDS, LEADERBOARD
-- ---------------------------------------------------------------------
create table earn_tasks (
  id serial primary key,
  title text not null,
  task_type text not null check (task_type in ('join_channel','follow_link','invite','daily_checkin','custom')),
  url text,
  verify_mode text not null default 'telegram_member' check (verify_mode in ('telegram_member','callback','manual')),
  reward_currency ledger_currency not null default 'cash',
  reward_amount numeric(30,9) not null default 0,
  is_daily boolean not null default false,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz
);

create table task_completions (
  id uuid primary key default gen_random_uuid(),
  task_id int not null references earn_tasks(id),
  player_id uuid not null references players(id),
  period date not null default '1970-01-01',   -- today's date for daily tasks
  status text not null default 'claimed' check (status in ('pending','claimed','rejected')),
  created_at timestamptz not null default now(),
  unique (task_id, player_id, period)
);

create table rewards (
  id serial primary key,
  name text not null,
  reward_type text not null check (reward_type in ('daily_login','streak','promo_code','season_prize','custom')),
  code text unique,
  currency ledger_currency not null default 'cash',
  amount numeric(30,9) not null default 0,
  max_uses int,
  used_count int not null default 0,
  config jsonb not null default '{}',
  is_active boolean not null default true,
  expires_at timestamptz
);

create table reward_claims (
  id uuid primary key default gen_random_uuid(),
  reward_id int not null references rewards(id),
  player_id uuid not null references players(id),
  period date not null default '1970-01-01',
  created_at timestamptz not null default now(),
  unique (reward_id, player_id, period)
);

create table leaderboard_seasons (
  id serial primary key,
  name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  prize_pool jsonb not null default '[]',
  status text not null default 'active' check (status in ('upcoming','active','ended'))
);

create table leaderboard_scores (
  season_id int not null references leaderboard_seasons(id),
  player_id uuid not null references players(id),
  score bigint not null default 0,
  yellow bigint not null default 0,
  rounds int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (season_id, player_id)
);
create index on leaderboard_scores(season_id, score desc);

-- ---------------------------------------------------------------------
-- 7. ANTI-CHEAT, ADMIN, AUDIT
-- ---------------------------------------------------------------------
create table anticheat_flags (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  round_id uuid references rounds(id),
  rule text not null,
  severity int not null check (severity between 1 and 5),
  details jsonb not null default '{}',
  status text not null default 'open' check (status in ('open','confirmed','dismissed')),
  reviewed_by uuid,
  created_at timestamptz not null default now()
);
create index on anticheat_flags(status, severity desc);
create index on anticheat_flags(player_id);

create table bans (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  reason text not null,
  banned_by uuid,
  active boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table admin_users (
  user_id uuid primary key,                -- = auth.users.id (Supabase Auth, enable MFA)
  email text not null,
  role text not null default 'viewer' check (role in ('owner','admin','support','viewer')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table audit_log (
  id bigint generated always as identity primary key,
  actor_type text not null check (actor_type in ('admin','system','player')),
  actor_id uuid,
  action text not null,
  entity text,
  entity_id text,
  before jsonb,
  after jsonb,
  ip inet,
  created_at timestamptz not null default now()
);
create index on audit_log(created_at desc);
create index on audit_log(entity, entity_id);

-- ledger and audit log can never be edited or deleted
create or replace function forbid_mutation() returns trigger language plpgsql as
$$ begin raise exception 'append-only table'; end $$;
create trigger ledger_ro before update or delete on ledger for each row execute function forbid_mutation();
create trigger audit_ro before update or delete on audit_log for each row execute function forbid_mutation();

-- =====================================================================
-- FUNCTIONS (all SECURITY DEFINER, granted to service_role only)
-- =====================================================================

create or replace function write_audit(p_type text, p_actor uuid, p_action text, p_entity text,
  p_entity_id text, p_before jsonb default null, p_after jsonb default null, p_ip inet default null)
returns void language sql security definer set search_path = public as
$$ insert into audit_log(actor_type, actor_id, action, entity, entity_id, before, after, ip)
   values (p_type, p_actor, p_action, p_entity, p_entity_id, p_before, p_after, p_ip) $$;

create or replace function assert_admin(p_admin uuid, p_roles text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from admin_users where user_id = p_admin and is_active and role = any(p_roles)) then
    raise exception 'forbidden';
  end if;
end $$;

-- anti-cheat flag + trust score drop
create or replace function raise_flag(p_player uuid, p_round uuid, p_rule text, p_sev int, p_details jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into anticheat_flags(player_id, round_id, rule, severity, details)
  values (p_player, p_round, p_rule, p_sev, p_details);
  update players
     set trust_score = greatest(0, trust_score - p_sev * 5),
         status = case when status = 'active' and greatest(0, trust_score - p_sev * 5) < cfg_int('trust_flag_below')
                       then 'flagged' else status end
   where id = p_player;
end $$;

-- atomic wallet change + ledger row. CHECK (>= 0) blocks overdraw.
create or replace function wallet_apply(p_player uuid, p_cur ledger_currency, p_amt numeric,
  p_kind text, p_ref_type text default null, p_ref uuid default null, p_meta jsonb default '{}')
returns numeric language plpgsql security definer set search_path = public as $$
declare nb numeric;
begin
  if p_cur = 'yellow' then
    update player_wallets set yellow = yellow + p_amt::bigint, updated_at = now() where player_id = p_player returning yellow into nb;
  elsif p_cur = 'cash' then
    update player_wallets set cash = cash + p_amt::bigint, updated_at = now() where player_id = p_player returning cash into nb;
  elsif p_cur = 'blue' then
    update player_wallets set blue = blue + p_amt::bigint, updated_at = now() where player_id = p_player returning blue into nb;
  else
    update player_wallets set pxn = pxn + p_amt, updated_at = now() where player_id = p_player returning pxn into nb;
  end if;
  if nb is null then raise exception 'wallet_missing'; end if;
  insert into ledger(player_id, currency, amount, balance_after, kind, ref_type, ref_id, meta)
  values (p_player, p_cur, p_amt, nb, p_kind, p_ref_type, p_ref, p_meta);
  return nb;
end $$;

-- lazy energy regen: no cron needed
create or replace function calc_energy(p_energy int, p_updated timestamptz)
returns table(out_energy int, out_updated timestamptz) language plpgsql stable as $$
declare cap int := cfg_int('energy_cap'); regen bigint := cfg_int('energy_regen_seconds'); gained int;
begin
  if p_energy >= cap then return query select p_energy, now(); return; end if;
  gained := floor(extract(epoch from (now() - p_updated)) / regen)::int;
  if gained <= 0 then return query select p_energy, p_updated; return; end if;
  if p_energy + gained >= cap then return query select cap, now();
  else return query select p_energy + gained, p_updated + make_interval(secs => gained * regen);
  end if;
end $$;

create or replace function get_energy(p_player uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl players%rowtype; e record; ads int;
begin
  select * into pl from players where id = p_player;
  select * into e from calc_energy(pl.energy, pl.energy_updated_at);
  select count(*) into ads from ad_sessions where player_id = p_player and status = 'completed'
     and day = (now() at time zone 'utc')::date;
  return jsonb_build_object('energy', e.out_energy, 'cap', cfg_int('energy_cap'),
    'next_in_seconds', case when e.out_energy >= cfg_int('energy_cap') then null
       else greatest(0, cfg_int('energy_regen_seconds') - extract(epoch from now() - e.out_updated))::int end,
    'ads_left', greatest(0, cfg_int('ads_per_day') - ads));
end $$;

create or replace function upsert_player_from_tg(p_tg_id bigint, p_username text, p_first text,
  p_lang text, p_premium boolean, p_device text default null, p_ip inet default null)
returns players language plpgsql security definer set search_path = public as $$
declare pl players; dev_users int;
begin
  insert into players(tg_id, username, first_name, language_code, is_premium, energy)
  values (p_tg_id, p_username, p_first, p_lang, p_premium, cfg_int('energy_cap'))
  on conflict (tg_id) do update
     set username = excluded.username, first_name = excluded.first_name,
         language_code = excluded.language_code, is_premium = excluded.is_premium, last_seen_at = now()
  returning * into pl;
  insert into player_wallets(player_id) values (pl.id) on conflict do nothing;
  if p_device is not null then
    insert into player_devices(player_id, device_hash, ip) values (pl.id, p_device, p_ip)
    on conflict (player_id, device_hash) do update set last_seen = now(), ip = excluded.ip;
    select count(distinct player_id) into dev_users from player_devices where device_hash = p_device;
    if dev_users > 3 then
      perform raise_flag(pl.id, null, 'multi_account_device', 2, jsonb_build_object('accounts', dev_users));
    end if;
  end if;
  return pl;
end $$;

-- ---- ROUND START: spends 1 energy, server creates the seed ----
create or replace function start_round(p_player uuid, p_ip inet default null)
returns table(o_round_id uuid, o_seed bigint, o_expires_at timestamptz, o_energy_left int)
language plpgsql security definer set search_path = public, extensions as $$
declare pl players%rowtype; e record; rid uuid; sd bigint; exp timestamptz;
begin
  select * into pl from players where id = p_player for update;
  if not found then raise exception 'player_not_found'; end if;
  if pl.status = 'banned' then raise exception 'banned'; end if;
  update rounds set status = 'expired', finished_at = now()
   where player_id = p_player and status = 'active' and expires_at < now();
  if exists (select 1 from rounds where player_id = p_player and status = 'active') then
    raise exception 'round_already_active';
  end if;
  select * into e from calc_energy(pl.energy, pl.energy_updated_at);
  if e.out_energy < cfg_int('energy_per_round') then raise exception 'no_energy'; end if;
  update players set energy = e.out_energy - cfg_int('energy_per_round'), energy_updated_at = e.out_updated
   where id = p_player;
  sd := ('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint;
  exp := now() + make_interval(secs => cfg_int('round_max_seconds'));
  insert into rounds(player_id, seed, expires_at, ip) values (p_player, sd, exp, p_ip) returning id into rid;
  return query select rid, sd, exp, e.out_energy - cfg_int('energy_per_round')::int;
end $$;

-- ---- ROUND FINISH: called by Edge Function AFTER it verified the event log ----
create or replace function finish_round(p_round uuid, p_accepted boolean, p_score bigint, p_cash bigint,
  p_blue bigint, p_yellow bigint, p_duration_ms int, p_events int, p_verdict jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare r rounds%rowtype; elapsed_ms bigint; cap_round bigint; earned_today bigint; y bigint; sid int;
begin
  select * into r from rounds where id = p_round for update;
  if not found then raise exception 'round_not_found'; end if;
  if r.status <> 'active' then raise exception 'round_not_active'; end if;
  elapsed_ms := (extract(epoch from now() - r.started_at) * 1000)::bigint;

  if not p_accepted or r.expires_at < now()
     or p_duration_ms < cfg_int('round_min_seconds') * 1000
     or p_duration_ms > elapsed_ms + 2000 then
    update rounds set status = 'rejected', finished_at = now(), verdict = p_verdict where id = p_round;
    perform raise_flag(r.player_id, p_round, 'round_rejected', 2, p_verdict);
    return jsonb_build_object('ok', false);
  end if;

  cap_round := least(cfg_int('max_yellow_per_round'),
                     ceil(p_duration_ms / 60000.0 * cfg_int('max_yellow_per_minute'))::bigint);
  select coalesce(sum(yellow), 0) into earned_today from rounds
   where player_id = r.player_id and status = 'finished' and finished_at >= date_trunc('day', now());
  y := greatest(0, least(p_yellow, cap_round, cfg_int('max_yellow_per_day') - earned_today));
  if p_yellow > cap_round then
    perform raise_flag(r.player_id, p_round, 'yellow_over_cap', 3,
      jsonb_build_object('claimed', p_yellow, 'cap', cap_round));
  end if;

  update rounds set status = 'finished', finished_at = now(), duration_ms = p_duration_ms,
         score = p_score, cash = least(p_cash, 1000), blue = least(p_blue, 1000), yellow = y,
         events_count = p_events, verdict = p_verdict where id = p_round;
  if y > 0 then
    perform wallet_apply(r.player_id, 'yellow', y, 'round_reward', 'round', p_round);
    update player_wallets set lifetime_yellow = lifetime_yellow + y where player_id = r.player_id;
  end if;
  if p_cash > 0 then perform wallet_apply(r.player_id, 'cash', least(p_cash, 1000), 'round_reward', 'round', p_round); end if;
  if p_blue > 0 then perform wallet_apply(r.player_id, 'blue', least(p_blue, 1000), 'round_reward', 'round', p_round); end if;

  select id into sid from leaderboard_seasons where status = 'active' order by starts_at desc limit 1;
  if sid is not null then
    insert into leaderboard_scores(season_id, player_id, score, yellow, rounds)
    values (sid, r.player_id, p_score, y, 1)
    on conflict (season_id, player_id) do update
      set score = leaderboard_scores.score + excluded.score,
          yellow = leaderboard_scores.yellow + excluded.yellow,
          rounds = leaderboard_scores.rounds + 1, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'yellow', y, 'cash', p_cash, 'blue', p_blue, 'score', p_score);
end $$;

-- ---- ADS: start, then the ad network's server callback completes it ----
create or replace function ad_start(p_player uuid, p_network text)
returns uuid language plpgsql security definer set search_path = public as $$
declare pl players%rowtype; cnt int; lastt timestamptz; sid uuid;
begin
  select * into pl from players where id = p_player for update;
  if pl.status = 'banned' then raise exception 'banned'; end if;
  select count(*) into cnt from ad_sessions where player_id = p_player
     and day = (now() at time zone 'utc')::date and status in ('started','completed');
  if cnt >= cfg_int('ads_per_day') then raise exception 'ad_limit_reached'; end if;
  select max(started_at) into lastt from ad_sessions where player_id = p_player;
  if lastt is not null and now() - lastt < make_interval(secs => cfg_int('ad_cooldown_seconds')) then
    raise exception 'ad_cooldown';
  end if;
  insert into ad_sessions(player_id, network) values (p_player, p_network) returning id into sid;
  return sid;
end $$;

create or replace function ad_complete(p_session uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s ad_sessions%rowtype; pl players%rowtype; e record;
begin
  select * into s from ad_sessions where id = p_session for update;
  if not found or s.status <> 'started' then raise exception 'bad_ad_session'; end if;
  if now() - s.started_at < make_interval(secs => cfg_int('ad_min_watch_seconds')) then
    update ad_sessions set status = 'rejected' where id = p_session;
    perform raise_flag(s.player_id, null, 'ad_too_fast', 2, jsonb_build_object('session', p_session));
    raise exception 'ad_too_fast';
  end if;
  select * into pl from players where id = s.player_id for update;
  select * into e from calc_energy(pl.energy, pl.energy_updated_at);
  update players set energy = e.out_energy + 1, energy_updated_at = e.out_updated where id = s.player_id;
  update ad_sessions set status = 'completed', completed_at = now() where id = p_session;
  return jsonb_build_object('energy', e.out_energy + 1);
end $$;

-- ---- SWAP yellow -> PXN (internal balance) ----
create or replace function swap_yellow_to_pxn(p_player uuid, p_yellow bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare tc token_config%rowtype; pl players%rowtype; gross numeric; fee numeric; net numeric; sid uuid := gen_random_uuid();
begin
  select * into pl from players where id = p_player for update;
  if pl.status <> 'active' then raise exception 'account_restricted'; end if;
  select * into tc from token_config where id = 1;
  if not tc.swap_enabled then raise exception 'swap_disabled'; end if;
  if p_yellow < tc.min_swap_yellow then raise exception 'below_min_swap'; end if;
  gross := p_yellow / tc.yellow_per_pxn;
  fee := round(gross * tc.swap_fee_bps / 10000.0, 9);
  net := round(gross - fee, 9);
  perform wallet_apply(p_player, 'yellow', -p_yellow, 'swap_out', 'swap', sid);
  perform wallet_apply(p_player, 'pxn', net, 'swap_in', 'swap', sid);
  insert into swaps(id, player_id, yellow_in, pxn_out, fee_pxn, rate) values (sid, p_player, p_yellow, net, fee, tc.yellow_per_pxn);
  return jsonb_build_object('pxn', net, 'rate', tc.yellow_per_pxn);
end $$;

-- ---- WITHDRAWAL REQUEST: locks PXN until admin decides ----
create or replace function request_withdrawal(p_player uuid, p_pxn numeric, p_address text)
returns uuid language plpgsql security definer set search_path = public as $$
declare pl players%rowtype; wid uuid := gen_random_uuid(); today_sum numeric; risk int := 0;
begin
  select * into pl from players where id = p_player for update;
  if not (cfg(('withdraw_enabled'))::text = 'true') then raise exception 'withdraw_disabled'; end if;
  if pl.status <> 'active' then raise exception 'account_restricted'; end if;
  if pl.trust_score < cfg_int('withdraw_min_trust') then raise exception 'low_trust'; end if;
  if now() - pl.created_at < make_interval(hours => cfg_int('withdraw_min_account_age_hours')::int) then
    raise exception 'account_too_new';
  end if;
  if p_address !~ '^(EQ|UQ)[A-Za-z0-9_-]{46}$' then raise exception 'bad_ton_address'; end if;
  if p_pxn < cfg_num('withdraw_min_pxn') or p_pxn > cfg_num('withdraw_max_pxn') then raise exception 'amount_out_of_range'; end if;
  if exists (select 1 from anticheat_flags where player_id = p_player and status = 'open' and severity >= 3) then
    raise exception 'under_review';
  end if;
  select coalesce(sum(pxn_amount), 0) into today_sum from withdrawals
   where player_id = p_player and status in ('pending','approved','paid') and created_at >= date_trunc('day', now());
  if today_sum + p_pxn > cfg_num('withdraw_daily_cap_pxn') then raise exception 'daily_cap'; end if;
  if exists (select 1 from player_devices d where d.player_id = p_player
             and (select count(distinct player_id) from player_devices where device_hash = d.device_hash) > 1) then
    risk := risk + 30;
  end if;
  risk := risk + (100 - pl.trust_score);
  perform wallet_apply(p_player, 'pxn', -p_pxn, 'withdraw_hold', 'withdrawal', wid);
  insert into withdrawals(id, player_id, pxn_amount, to_address, risk_score) values (wid, p_player, p_pxn, p_address, risk);
  update players set ton_wallet = p_address where id = p_player;
  return wid;
end $$;

-- ---- ADMIN: approve / reject / mark paid (every action audited) ----
create or replace function admin_review_withdrawal(p_admin uuid, p_id uuid, p_action text,
  p_reason text default null, p_tx text default null, p_ip inet default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w withdrawals%rowtype; old jsonb;
begin
  perform assert_admin(p_admin, array['owner','admin']);
  select * into w from withdrawals where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  old := to_jsonb(w);
  if p_action = 'approve' and w.status = 'pending' then
    update withdrawals set status = 'approved', reviewed_by = p_admin, reviewed_at = now() where id = p_id;
  elsif p_action = 'reject' and w.status = 'pending' then
    if p_reason is null then raise exception 'reason_required'; end if;
    update withdrawals set status = 'rejected', reject_reason = p_reason, reviewed_by = p_admin, reviewed_at = now() where id = p_id;
    perform wallet_apply(w.player_id, 'pxn', w.pxn_amount, 'withdraw_refund', 'withdrawal', p_id);
  elsif p_action = 'paid' and w.status = 'approved' then
    if p_tx is null then raise exception 'tx_hash_required'; end if;
    update withdrawals set status = 'paid', tx_hash = p_tx where id = p_id;
  elsif p_action = 'failed' and w.status = 'approved' then
    update withdrawals set status = 'failed', reject_reason = p_reason where id = p_id;
    perform wallet_apply(w.player_id, 'pxn', w.pxn_amount, 'withdraw_refund', 'withdrawal', p_id);
  else
    raise exception 'invalid_transition';
  end if;
  perform write_audit('admin', p_admin, 'withdrawal_' || p_action, 'withdrawal', p_id::text, old,
                      (select to_jsonb(x) from withdrawals x where id = p_id), p_ip);
  return jsonb_build_object('ok', true);
end $$;

-- ---- ADMIN: ban / unban, resolve flag ----
create or replace function admin_ban_player(p_admin uuid, p_player uuid, p_ban boolean, p_reason text, p_ip inet default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin(p_admin, array['owner','admin','support']);
  if p_ban then
    update players set status = 'banned' where id = p_player;
    insert into bans(player_id, reason, banned_by) values (p_player, p_reason, p_admin);
  else
    update players set status = 'active', trust_score = greatest(trust_score, 60) where id = p_player;
    update bans set active = false where player_id = p_player and active;
  end if;
  perform write_audit('admin', p_admin, case when p_ban then 'ban' else 'unban' end, 'player', p_player::text,
                      null, jsonb_build_object('reason', p_reason), p_ip);
end $$;

create or replace function admin_set_rate(p_admin uuid, p_yellow_per_pxn numeric, p_ip inet default null)
returns void language plpgsql security definer set search_path = public as $$
declare old numeric;
begin
  perform assert_admin(p_admin, array['owner']);
  select yellow_per_pxn into old from token_config where id = 1;
  update token_config set yellow_per_pxn = p_yellow_per_pxn, updated_at = now() where id = 1;
  insert into token_rate_history(yellow_per_pxn, changed_by) values (p_yellow_per_pxn, p_admin);
  perform write_audit('admin', p_admin, 'set_rate', 'token_config', '1',
                      jsonb_build_object('rate', old), jsonb_build_object('rate', p_yellow_per_pxn), p_ip);
end $$;

-- =====================================================================
-- VIEWS (service_role / admin Edge Functions only)
-- =====================================================================
create or replace view admin_dashboard with (security_invoker = true) as
select
  (select count(*) from players) as total_players,
  (select count(*) from players where last_seen_at > now() - interval '24 hours') as dau,
  (select count(*) from rounds where started_at > now() - interval '24 hours') as rounds_24h,
  (select coalesce(sum(yellow), 0) from rounds where status = 'finished' and started_at > now() - interval '24 hours') as yellow_minted_24h,
  (select coalesce(sum(yellow), 0) from player_wallets) as yellow_in_circulation,
  (select count(*) from withdrawals where status = 'pending') as pending_withdrawals,
  (select coalesce(sum(pxn_amount), 0) from withdrawals where status = 'pending') as pending_pxn,
  (select count(*) from anticheat_flags where status = 'open') as open_flags,
  (select count(*) from players where status = 'banned') as banned_players;

create or replace view leaderboard_current with (security_invoker = true) as
select ls.season_id, p.id as player_id, p.username, p.first_name, ls.score, ls.yellow, ls.rounds,
       rank() over (partition by ls.season_id order by ls.score desc) as rank
from leaderboard_scores ls
join players p on p.id = ls.player_id and p.status <> 'banned'
join leaderboard_seasons s on s.id = ls.season_id and s.status = 'active';

-- =====================================================================
-- SECURITY: RLS everywhere, no client writes, RPCs only for service_role
-- =====================================================================
do $do$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $do$;

revoke all on admin_dashboard, leaderboard_current from anon, authenticated;

-- players may only READ their own rows (custom JWT: sub = players.id) + public catalogs
grant select on players, player_wallets, player_drills to authenticated;
create policy own_player on players for select to authenticated using (id = auth.uid());
create policy own_wallet on player_wallets for select to authenticated using (player_id = auth.uid());
create policy own_drills on player_drills for select to authenticated using (player_id = auth.uid());

grant select on drills, store_items, earn_tasks, token_config to authenticated;
create policy read_drills on drills for select to authenticated using (is_active);
create policy read_store on store_items for select to authenticated using (is_active);
create policy read_tasks on earn_tasks for select to authenticated using (is_active);
create policy read_token on token_config for select to authenticated using (true);

do $do$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f'
             and p.proname in ('start_round','finish_round','ad_start','ad_complete','swap_yellow_to_pxn',
               'request_withdrawal','admin_review_withdrawal','admin_ban_player','admin_set_rate',
               'upsert_player_from_tg','get_energy','wallet_apply','raise_flag','write_audit','assert_admin')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $do$;

-- =====================================================================
-- SEED
-- =====================================================================
insert into drills(name, rarity, speed_mult, hp_bonus) values
  ('Starter Drill', 'common', 1.00, 0);
insert into leaderboard_seasons(name, starts_at, ends_at, status)
  values ('Season 1', now(), now() + interval '30 days', 'active');
insert into earn_tasks(title, task_type, verify_mode, reward_currency, reward_amount, is_daily)
  values ('Daily check-in', 'daily_checkin', 'callback', 'cash', 10, true);
