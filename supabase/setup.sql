-- =====================================================================
-- 全球靜默空間 Global Silence Space — database setup
-- Paste this whole file into Supabase → SQL Editor → Run.
-- Safe to run again: it only creates what is missing and refreshes functions.
--
-- Design: the website never touches tables directly. Every action goes
-- through a few functions below. Each phone gets a private id + secret;
-- the server keeps the clock, so sitting time can't be typed in by hand.
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.gs_users (
  id            uuid primary key default gen_random_uuid(),
  secret_hash   text not null,
  name          text not null default '',
  country       text not null default '',
  total_seconds integer not null default 0,
  created_at    timestamptz not null default now(),
  last_seen     timestamptz not null default now()
);
create index if not exists gs_users_total_idx on public.gs_users (total_seconds desc);

create table if not exists public.gs_events (
  key          text primary key,          -- e.g. 'first-sit'
  title        text not null,
  starts_at    timestamptz not null,      -- sessions that START inside this window take part
  start_until  timestamptz not null,
  min_seconds  integer not null,          -- one continuous sit of at least this long earns a code
  code_prefix  text not null
);

create table if not exists public.gs_sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.gs_users(id) on delete cascade,
  started_at      timestamptz not null default now(),
  last_beat       timestamptz not null default now(),
  ended_at        timestamptz,
  seconds         integer not null default 0,
  event_key       text references public.gs_events(key),
  completion_code text unique,
  completed_at    timestamptz
);
create index if not exists gs_sessions_user_idx on public.gs_sessions (user_id);
create index if not exists gs_sessions_event_idx on public.gs_sessions (event_key) where completion_code is not null;

-- Lock the tables: no direct reading or writing from the website.
alter table public.gs_users    enable row level security;
alter table public.gs_events   enable row level security;
alter table public.gs_sessions enable row level security;
revoke all on table public.gs_users, public.gs_events, public.gs_sessions from anon, authenticated;

-- ---------- events ----------
insert into public.gs_events (key, title, starts_at, start_until, min_seconds, code_prefix) values
  ('rehearsal', '彩排測試（坐滿 5 分鐘）', '2026-11-04 00:00+08', '2026-11-07 23:59+08', 300,  'TEST'),
  ('first-sit', '第一場線上共修',          '2026-11-08 20:50+08', '2026-11-09 00:00+08', 2700, 'GS')
on conflict (key) do update set title=excluded.title, starts_at=excluded.starts_at,
  start_until=excluded.start_until, min_seconds=excluded.min_seconds, code_prefix=excluded.code_prefix;

-- ---------- helpers (not callable from the website) ----------
create or replace function public.gs_hash(p_secret text) returns text
language sql immutable as $$ select encode(sha256(convert_to(coalesce(p_secret,''),'UTF8')),'hex') $$;

create or replace function public.gs_ok(p_id uuid, p_secret text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gs_users where id = p_id and secret_hash = gs_hash(p_secret))
$$;

create or replace function public.gs_clean(p_text text) returns text
language sql immutable as $$ select left(btrim(regexp_replace(coalesce(p_text,''), '[[:cntrl:]<>]', '', 'g')), 16) $$;

-- ---------- API: called by the website ----------

-- First visit from a phone: create a profile. p_import carries over time sat before the server existed (capped at 3 hours).
create or replace function public.gs_register(p_name text, p_country text, p_import integer default 0) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v_secret text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''); v_id uuid;
begin
  if gs_clean(p_name) = '' or gs_clean(p_country) = '' then raise exception 'name and country required'; end if;
  insert into gs_users (secret_hash, name, country, total_seconds)
  values (gs_hash(v_secret), gs_clean(p_name), gs_clean(p_country), least(greatest(coalesce(p_import,0),0), 10800))
  returning id into v_id;
  return json_build_object('id', v_id, 'secret', v_secret);
end $$;

-- Later visits: update nickname / where from.
create or replace function public.gs_profile(p_id uuid, p_secret text, p_name text, p_country text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v_total integer;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  update gs_users set name = coalesce(nullif(gs_clean(p_name),''), name), country = coalesce(nullif(gs_clean(p_country),''), country), last_seen = now()
  where id = p_id returning total_seconds into v_total;
  return json_build_object('total', v_total);
end $$;

-- Pressing 開始靜坐.
create or replace function public.gs_start(p_id uuid, p_secret text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v_session uuid; v_event gs_events;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  update gs_sessions set ended_at = last_beat where user_id = p_id and ended_at is null;   -- close anything left open
  select * into v_event from gs_events where now() between starts_at and start_until order by starts_at desc limit 1;
  insert into gs_sessions (user_id, event_key) values (p_id, v_event.key) returning id into v_session;
  update gs_users set last_seen = now() where id = p_id;
  return json_build_object('session', v_session, 'event', v_event.key, 'event_title', v_event.title, 'min_seconds', v_event.min_seconds);
end $$;

-- Every ~20 s while sitting. The server's own clock decides how much counts:
-- a gap over 45 s (camera covered, app in background, lost signal) adds nothing.
create or replace function public.gs_beat(p_id uuid, p_secret text, p_session uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare s gs_sessions; v_add integer; v_secs integer; v_total integer; v_code text; v_event gs_events;
        v_abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i integer;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  select * into s from gs_sessions where id = p_session and user_id = p_id and ended_at is null for update;
  if not found then return json_build_object('error','session'); end if;
  v_add := floor(extract(epoch from now() - s.last_beat))::integer;
  if v_add < 0 or v_add > 45 then v_add := 0; end if;
  update gs_sessions set seconds = seconds + v_add, last_beat = now() where id = s.id returning seconds into v_secs;
  update gs_users set total_seconds = total_seconds + v_add, last_seen = now() where id = p_id returning total_seconds into v_total;
  v_code := s.completion_code;
  if s.event_key is not null and v_code is null then
    select * into v_event from gs_events where key = s.event_key;
    if v_secs >= v_event.min_seconds then
      loop
        v_code := v_event.code_prefix || '-';
        for i in 1..4 loop v_code := v_code || substr(v_abc, 1 + floor(random() * length(v_abc))::integer, 1); end loop;
        begin
          update gs_sessions set completion_code = v_code, completed_at = now() where id = s.id;
          exit;
        exception when unique_violation then -- try another code
        end;
      end loop;
    end if;
  end if;
  return json_build_object('seconds', v_secs, 'total', v_total, 'code', v_code, 'event', s.event_key);
end $$;

-- Pressing 起座 (or being stood up automatically).
create or replace function public.gs_end(p_id uuid, p_secret text, p_session uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v json;
begin
  v := gs_beat(p_id, p_secret, p_session);
  if v->>'error' is null then update gs_sessions set ended_at = now() where id = p_session and user_id = p_id; end if;
  return v;
end $$;

-- Leaderboard + whole-mountain total. Nothing private leaves the server.
-- (free.sql replaces this with a version whose world total also counts 自由靜坐 — if you re-run this file, run free.sql again after it.)
create or replace function public.gs_board(p_id uuid default null, p_limit integer default 10) returns json
language plpgsql stable security definer set search_path = public as $$
declare v_top json; v_me json; v_total bigint; v_people integer; v_mine integer;
begin
  select coalesce(json_agg(json_build_object('n', name, 'c', country, 't', total_seconds, 'me', id = p_id) order by total_seconds desc, created_at), '[]'::json)
    into v_top
    from (select * from gs_users where total_seconds > 0 order by total_seconds desc, created_at limit least(greatest(coalesce(p_limit,10),1),50)) x;
  select coalesce(sum(total_seconds),0), count(*) filter (where total_seconds > 0) into v_total, v_people from gs_users;
  if p_id is not null then
    select total_seconds into v_mine from gs_users where id = p_id;
    if found then
      v_me := json_build_object('t', v_mine, 'rank', (select count(*) + 1 from gs_users where total_seconds > v_mine));
    end if;
  end if;
  return json_build_object('top', v_top, 'me', v_me, 'total', v_total, 'people', v_people);
end $$;

-- ---------- permissions ----------
revoke all on function public.gs_hash(text), public.gs_ok(uuid,text), public.gs_clean(text) from public, anon, authenticated;
revoke all on function public.gs_register(text,text,integer), public.gs_profile(uuid,text,text,text), public.gs_start(uuid,text),
  public.gs_beat(uuid,text,uuid), public.gs_end(uuid,text,uuid), public.gs_board(uuid,integer) from public;
grant execute on function public.gs_register(text,text,integer), public.gs_profile(uuid,text,text,text), public.gs_start(uuid,text),
  public.gs_beat(uuid,text,uuid), public.gs_end(uuid,text,uuid), public.gs_board(uuid,integer) to anon, authenticated;

-- ---------- for the organiser (SQL Editor only, never exposed to the website) ----------
create or replace view public.gs_completions as
  select s.event_key as 活動, s.completion_code as 完成碼, u.name as 暱稱, u.country as 來自,
         round(s.seconds / 60.0, 1) as 分鐘,
         to_char(s.started_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') as 開始_台灣時間,
         to_char(s.completed_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') as 完成_台灣時間
  from gs_sessions s join gs_users u on u.id = s.user_id
  where s.completion_code is not null
  order by s.completed_at;
revoke all on public.gs_completions from anon, authenticated;
