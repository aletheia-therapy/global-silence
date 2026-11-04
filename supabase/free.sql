-- =====================================================================
-- 全球靜默空間 — 自由靜坐 adds to the WORLD total (never to anyone's own hours)
-- Paste into Supabase → SQL Editor → Run. Safe to run again.
-- Same server-clock rule as formal sitting: a gap over 45 s counts nothing,
-- and one free sit counts at most 3 hours.
-- =====================================================================
create table if not exists public.gs_free (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references public.gs_users(id) on delete set null,
  started_at  timestamptz not null default now(),
  last_beat   timestamptz not null default now(),
  ended_at    timestamptz,
  seconds     integer not null default 0
);
create index if not exists gs_free_user_idx on public.gs_free (user_id) where ended_at is null;
alter table public.gs_free enable row level security;
revoke all on table public.gs_free from anon, authenticated;

-- Pressing 自由靜坐.
create or replace function public.gs_free_start(p_id uuid, p_secret text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v uuid;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  update gs_free set ended_at = last_beat where user_id = p_id and ended_at is null;  -- close anything left open
  insert into gs_free (user_id) values (p_id) returning id into v;
  return json_build_object('session', v);
end $$;

-- Every ~20 s while sitting freely.
create or replace function public.gs_free_beat(p_id uuid, p_secret text, p_session uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare s gs_free; v_add integer; v_secs integer;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  select * into s from gs_free where id = p_session and user_id = p_id and ended_at is null for update;
  if not found then return json_build_object('error','session'); end if;
  v_add := floor(extract(epoch from now() - s.last_beat))::integer;
  if v_add < 0 or v_add > 45 then v_add := 0; end if;
  v_add := least(v_add, greatest(0, 10800 - s.seconds));
  update gs_free set seconds = seconds + v_add, last_beat = now() where id = s.id returning seconds into v_secs;
  return json_build_object('seconds', v_secs);
end $$;

-- Pressing 起座 (or leaving the page).
create or replace function public.gs_free_end(p_id uuid, p_secret text, p_session uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v json;
begin
  v := gs_free_beat(p_id, p_secret, p_session);
  if v->>'error' is null then update gs_free set ended_at = now() where id = p_session and user_id = p_id; end if;
  return v;
end $$;

-- Leaderboard + world total: the world total now includes free sitting; personal hours do not.
create or replace function public.gs_board(p_id uuid default null, p_limit integer default 10) returns json
language plpgsql stable security definer set search_path = public as $$
declare v_top json; v_me json; v_total bigint; v_people integer; v_mine integer; v_free bigint;
begin
  select coalesce(json_agg(json_build_object('n', name, 'c', country, 't', total_seconds, 'me', id = p_id) order by total_seconds desc, created_at), '[]'::json)
    into v_top
    from (select * from gs_users where total_seconds > 0 order by total_seconds desc, created_at limit least(greatest(coalesce(p_limit,10),1),50)) x;
  select coalesce(sum(total_seconds),0), count(*) filter (where total_seconds > 0) into v_total, v_people from gs_users;
  select coalesce(sum(seconds),0) into v_free from gs_free;
  if p_id is not null then
    select total_seconds into v_mine from gs_users where id = p_id;
    if found then
      v_me := json_build_object('t', v_mine, 'rank', (select count(*) + 1 from gs_users where total_seconds > v_mine));
    end if;
  end if;
  return json_build_object('top', v_top, 'me', v_me, 'total', v_total + v_free, 'free', v_free, 'people', v_people);
end $$;

revoke all on function public.gs_free_start(uuid,text), public.gs_free_beat(uuid,text,uuid), public.gs_free_end(uuid,text,uuid) from public;
grant execute on function public.gs_free_start(uuid,text), public.gs_free_beat(uuid,text,uuid), public.gs_free_end(uuid,text,uuid), public.gs_board(uuid,integer) to anon, authenticated;
