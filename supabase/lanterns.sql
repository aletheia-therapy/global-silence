-- =====================================================================
-- 全球靜默空間 — 祈願燈 (wish lanterns)
-- Paste into Supabase → SQL Editor → Run. Safe to run again.
-- The wish text never reaches the server: only "a lantern was lit at this time".
-- =====================================================================
create table if not exists public.gs_lanterns (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.gs_users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists gs_lanterns_time_idx on public.gs_lanterns (created_at desc);
alter table public.gs_lanterns enable row level security;
revoke all on table public.gs_lanterns from anon, authenticated;

-- Light one lantern (at most one every 2 minutes per person).
create or replace function public.gs_light(p_id uuid, p_secret text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v gs_lanterns;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  if exists (select 1 from gs_lanterns where user_id = p_id and created_at > now() - interval '2 minutes') then
    return json_build_object('error','wait');
  end if;
  insert into gs_lanterns (user_id) values (p_id) returning * into v;
  return json_build_object('id', v.id, 't', extract(epoch from v.created_at));
end $$;

-- Lanterns lit in the last 7 days (newest 150), for everyone's sky.
create or replace function public.gs_lanterns() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'list', coalesce((select json_agg(json_build_object('id', id, 't', extract(epoch from created_at)) order by created_at desc)
                      from (select * from gs_lanterns where created_at > now() - interval '7 days' order by created_at desc limit 150) x), '[]'::json),
    'week', (select count(*) from gs_lanterns where created_at > now() - interval '7 days'),
    'all',  (select count(*) from gs_lanterns))
$$;

revoke all on function public.gs_light(uuid,text), public.gs_lanterns() from public;
grant execute on function public.gs_light(uuid,text), public.gs_lanterns() to anon, authenticated;
