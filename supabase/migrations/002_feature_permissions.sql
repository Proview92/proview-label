-- Proview Label: per-feature permissions for back-office logins.
-- Owners, admins and the Proview master always have every feature.
-- Managers have a `features` object, e.g. {"products":false,"orders":true}. A missing key means ON,
-- so managers created before this change keep the access they had.

alter table public.pl_members add column if not exists features jsonb not null default '{}'::jsonb;

-- Feature keys used by the back-office (keep in step with FEATURES in web/src/dashboard.html):
--   expiry, printlog, wastage, products, rules, orders, devices, users, history

create or replace function public.pl_has_feature(p_org text, p_feature text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return true; end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  return coalesce((m.features ->> p_feature)::boolean, true);
end $$;

-- Which feature a record kind belongs to when it is CHANGED. null = always allowed (the handheld needs it).
create or replace function public.pl_write_feature(p_kind text) returns text language sql immutable as $$
  select case p_kind
    when 'products' then 'products' when 'categories' then 'products'
    when 'rules' then 'rules' when 'orders' then 'orders'
    when 'devices' then 'devices' when 'users' then 'users'
    else null end $$;

-- Which feature a record kind belongs to when it is READ. Only kinds the handheld doesn't need are gated.
create or replace function public.pl_read_feature(p_kind text) returns text language sql immutable as $$
  select case p_kind when 'audit' then 'history' when 'orders' then 'orders' else null end $$;

create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; f text;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return true; end if;
  if exists (select 1 from public.pl_orgs where id = p_org and suspended) then return false; end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;              -- managers can't add or edit sites
  f := public.pl_write_feature(p_kind);
  if f is not null and not coalesce((m.features ->> f)::boolean, true) then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

create or replace function public.pl_can_read_kind(p_org text, p_site text, p_kind text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.pl_can_read(p_org, p_site)
     and (public.pl_read_feature(p_kind) is null or public.pl_has_feature(p_org, public.pl_read_feature(p_kind))) $$;

drop policy if exists "records read" on public.pl_records;
create policy "records read" on public.pl_records for select to authenticated
  using (public.pl_can_read_kind(org_id, site_id, kind));

-- whoami now also returns each business's feature switches for the signed-in person
create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean;
begin
  if auth.uid() is null then return null; end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  return jsonb_build_object('email', em, 'master', is_m,
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               where is_m or m.id is not null), '[]'::jsonb));
end $$;

-- A manager must not be able to give themselves features: only owners/admins update pl_members (existing policy),
-- and an admin can't edit an owner's row unless they are the owner (existing check). Nothing else to change.

revoke execute on function public.pl_has_feature(text, text), public.pl_can_read_kind(text, text, text) from public, anon;
grant execute on function public.pl_has_feature(text, text), public.pl_can_read_kind(text, text, text) to authenticated;
