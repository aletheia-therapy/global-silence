-- =====================================================================
-- 全球靜默空間 — 祝福蓮花 (blessing lotuses in the summit pond)
-- Paste into Supabase → SQL Editor → Run. Safe to run again.
-- Only the flower's place in the pond is stored — never the blessing text.
-- =====================================================================
create table if not exists public.gs_lotus (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.gs_users(id) on delete set null,
  x          real not null,
  z          real not null,
  created_at timestamptz not null default now()
);
create index if not exists gs_lotus_time_idx on public.gs_lotus (created_at desc);
alter table public.gs_lotus enable row level security;
revoke all on table public.gs_lotus from anon, authenticated;

-- Plant one lotus (at most one every 2 minutes per person).
create or replace function public.gs_plant(p_id uuid, p_secret text, p_x real, p_z real) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v gs_lotus;
begin
  if not gs_ok(p_id, p_secret) then return json_build_object('error','auth'); end if;
  if p_x is null or p_z is null or abs(p_x) > 60 or abs(p_z) > 60 then return json_build_object('error','place'); end if;
  if exists (select 1 from gs_lotus where user_id = p_id and created_at > now() - interval '2 minutes') then
    return json_build_object('error','wait');
  end if;
  insert into gs_lotus (user_id, x, z) values (p_id, p_x, p_z) returning * into v;
  return json_build_object('id', v.id, 'x', v.x, 'z', v.z, 't', extract(epoch from v.created_at));
end $$;

-- Lotuses planted in the last 14 days (newest 80), for everyone's pond.
create or replace function public.gs_lotuses() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'list', coalesce((select json_agg(json_build_object('id', id, 'x', x, 'z', z, 't', extract(epoch from created_at)) order by created_at desc)
                      from (select * from gs_lotus where created_at > now() - interval '14 days' order by created_at desc limit 80) q), '[]'::json),
    'all', (select count(*) from gs_lotus))
$$;

revoke all on function public.gs_plant(uuid,text,real,real), public.gs_lotuses() from public;
grant execute on function public.gs_plant(uuid,text,real,real), public.gs_lotuses() to anon, authenticated;
