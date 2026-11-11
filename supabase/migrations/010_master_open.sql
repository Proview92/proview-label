-- 010: master open (owner, 11 Nov 2026, MASTER_OPEN_SPEC.md: "the database tightening: ADD IT")
--
-- The master has no view of every business any more: they open ONE customer from the licence portal and the back-office
-- names it in the x-pl-org header on every request (004). The database now gives the master that business only:
--   * pl_whoami: the master's "orgs" is only the business named in x-pl-org (none without the header). No other
--     business's name, settings or licence states are sent.
--   * pl_records (pl_can_read_kind): the master no longer reads every business's sites and devices records (the old
--     All sites list); every kind, only for the business in x-pl-org (pl_master_in, as every other master check).
--   * pl_orgs (orgs read): the master reads only the business in x-pl-org.
-- Already scoped since 004/005: pl_devices, pl_members, writes (pl_can_write, pl_is_org_admin); now never null (0).
-- Unchanged on purpose:
--   * the licence portal: hub_call / hub_call_base / hub_plans / hub_private.* are SECURITY DEFINER, owned by postgres
--     (RLS not forced), and use none of the functions changed here; add_business still runs pl_add_business as the master;
--   * the master-only SECURITY DEFINER functions (pl_set_site_licence, pl_set_licence, pl_set_trial, pl_add_business);
--   * owners, admins, managers and handhelds: every branch for them is copied as it was (handhelds: pl_device_me()).
-- Safe before or after the new back-office: the old master UI just loses its every-business view (it sends no header
-- before a business is picked); the new one sends x-pl-org from its first request.

-- 0) "master inside this business" is always true or false, never null. Before, with no x-pl-org it was null, and an
--    RPC that tests "if not pl_is_org_admin(...)" / "if not pl_can_write(...)" let a null through. (RLS treats null as no.)
create or replace function public.pl_master_in(p_org text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_org = public.pl_req_org(), false) and public.pl_is_master() $$;

-- 1) per-business records: the master only inside the business named in x-pl-org
create or replace function public.pl_can_read_kind(p_org text, p_site text, p_kind text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when public.pl_is_master() then public.pl_master_in(p_org)
    else public.pl_can_read(p_org, p_site)
     and (public.pl_read_feature(p_kind) is null or public.pl_has_feature(p_org, public.pl_read_feature(p_kind))) end $$;

-- 2) businesses: the master reads only the open one; members their own (unchanged)
drop policy if exists "orgs read" on public.pl_orgs;
create policy "orgs read" on public.pl_orgs for select to authenticated
  using (public.pl_master_in(id) or exists (select 1 from public.pl_members m where m.org_id = pl_orgs.id and m.user_id = auth.uid()));

-- 3) whoami: as 009, except that the master's list is only the business in x-pl-org
create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean; d public.pl_devices; dl jsonb; req text;
begin
  if auth.uid() is null then return null; end if;
  d := public.pl_device_me();
  if d.id is not null then
    dl := coalesce(hub_private.pl_site_lic_json(d.site_id), jsonb_build_object('licensed', false, 'no_licence', true, 'expired', false));
    return jsonb_build_object('email', null, 'master', false, 'trial_used', false,
      'device', jsonb_build_object('id', d.id, 'name', d.name, 'mode', d.mode, 'site_id', d.site_id, 'org_id', d.org_id),
      'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', case when (dl->>'expired')::boolean then dl->>'licence_expires_at' end,
                 'trial_expired', coalesce((dl->>'expired')::boolean, false),
                 'licensed', not coalesce((dl->>'no_licence')::boolean, true), 'no_licence', coalesce((dl->>'no_licence')::boolean, true),
                 'locked', o.suspended or not public.pl_site_open(o.id, d.site_id),
                 'sites', jsonb_build_array(dl),
                 'role', 'device', 'site_ids', jsonb_build_array(d.site_id), 'member_id', null, 'features', '{}'::jsonb))
               from public.pl_orgs o where o.id = d.org_id), '[]'::jsonb));
  end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  req := public.pl_req_org();
  return jsonb_build_object('email', em, 'master', is_m,
    'trial_used', false,   -- kept so older app builds still offer "Set up your business"; no longer used
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', case when x.locked and x.had then x.last_end end,
                 'trial_expired', x.locked and x.had,
                 'licensed', not x.locked or (o.suspended and x.had), 'no_licence', x.locked and not o.suspended and not x.had,
                 'locked', x.locked,
                 'sites', coalesce((select jsonb_agg(hub_private.pl_site_lic_json(r.id) order by lower(coalesce(r.data->>'name', '')))
                                      from public.pl_records r where r.org_id = o.id and r.kind = 'sites' and not r.deleted
                                       and (is_m or m.role in ('owner','admin') or r.id = any(coalesce(m.site_ids, '{}')))), '[]'::jsonb),
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               cross join lateral (select public.pl_org_locked(o.id) as locked,
                   exists (select 1 from public.pl_site_licences l join public.pl_records r on r.id = l.site_id and not r.deleted
                            where l.org_id = o.id and l.licence_type is not null) as had,
                   (select max(l.licence_expires_at) from public.pl_site_licences l join public.pl_records r on r.id = l.site_id and not r.deleted
                     where l.org_id = o.id and l.licence_type is not null) as last_end) x
               where (is_m and req is not null and o.id = req) or (not is_m and m.id is not null)), '[]'::jsonb));
end $$;
