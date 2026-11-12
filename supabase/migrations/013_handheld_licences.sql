-- 013: Proview Label is licensed PER HANDHELD, not per location (owner, 12 Nov 2026: "Label does not require a location
-- licence, its licence works per [device]" → per handheld).
--
-- * public.pl_handheld_licences: one row per paired handheld (device_id), with licence_type / starts / expires / notes,
--   like the location licences of 009. Its id ('hl_…') is the unit the licence portal and Stripe use (pvl__<id>__<plan>).
--   Every paired handheld gets a row when it is paired (trigger on pl_devices); with no licence it is locked.
-- * Removing a handheld keeps a licence that is still running as a SPARE (device_id null): the next handheld paired in
--   that business takes it, so re-pairing a handheld never loses what was paid for.
-- * Locations need no licence: pl_site_open = business not suspended and the location live, so the back-office web
--   dashboard is never locked by licences. A handheld can print and sync while ITS licence is valid (pl_can_write,
--   pl_whoami reports the handheld's own licence in the fields its lock screen already reads: no APK change needed).
-- * Existing location licences: each paired handheld without a valid licence gets its location's licence; a licensed
--   location with no handheld becomes one spare licence for its business. pl_site_licences is kept but no longer read.
-- * Licence portal: hub_call 'list' returns one unit per handheld licence (kind 'handheld'); 'set' sets one;
--   'trial' (the portal's New customer → 3-day trial) gives the business a spare 3-day trial licence.
-- Safe to run more than once.

-- 1) the table
create table if not exists public.pl_handheld_licences(
  id text primary key default 'hl_' || replace(gen_random_uuid()::text, '-', ''),
  org_id text not null references public.pl_orgs(id) on delete cascade,
  device_id text unique,          -- null = spare: its handheld was removed; the next handheld paired here takes it
  licence_type text check (licence_type in ('trial','m1','m3','m6','m12','m24','m36','lifetime','custom')),
  licence_starts_at timestamptz,
  licence_expires_at timestamptz,
  notes text,
  updated_at timestamptz not null default now(),
  check (licence_type is null or licence_type = 'lifetime' or licence_expires_at is not null));
create index if not exists pl_handheld_licences_org on public.pl_handheld_licences(org_id);
alter table public.pl_handheld_licences enable row level security;
revoke all on table public.pl_handheld_licences from public, anon, authenticated;
comment on table public.pl_handheld_licences is
  'Licence of each paired handheld (device_id), or a spare (device_id null). Written only by the master''s functions and hub_call.';
comment on table public.pl_site_licences is 'RETIRED by migration 013: Label is licensed per handheld (pl_handheld_licences).';

create or replace function public.pl_lic_valid(p_type text, p_expires timestamptz) returns boolean
language sql stable as $$ select p_type is not null and (p_type = 'lifetime' or p_expires > now()) $$;

-- 2) every handheld has a row; removing one keeps a running licence as a spare
create or replace function public.pl_devices_licence() returns trigger
language plpgsql security definer set search_path = public as $$
declare sp text;
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from public.pl_handheld_licences where device_id = new.id) then
      select id into sp from public.pl_handheld_licences
       where org_id = new.org_id and device_id is null and public.pl_lic_valid(licence_type, licence_expires_at)
       order by licence_type = 'lifetime' desc, licence_expires_at desc nulls first limit 1 for update;
      if sp is not null then
        update public.pl_handheld_licences set device_id = new.id, updated_at = now() where id = sp;
      else
        insert into public.pl_handheld_licences(org_id, device_id) values (new.org_id, new.id);
      end if;
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    update public.pl_handheld_licences set org_id = new.org_id, updated_at = now() where device_id = new.id and org_id <> new.org_id;
    return new;
  else
    update public.pl_handheld_licences set device_id = null, updated_at = now()
     where device_id = old.id and public.pl_lic_valid(licence_type, licence_expires_at);
    delete from public.pl_handheld_licences where device_id = old.id;
    return old;
  end if;
end $$;
drop trigger if exists pl_devices_licence_ins on public.pl_devices;
drop trigger if exists pl_devices_licence_upd on public.pl_devices;
drop trigger if exists pl_devices_licence_del on public.pl_devices;
create trigger pl_devices_licence_ins after insert on public.pl_devices for each row execute function public.pl_devices_licence();
create trigger pl_devices_licence_upd after update of org_id on public.pl_devices for each row execute function public.pl_devices_licence();
create trigger pl_devices_licence_del after delete on public.pl_devices for each row execute function public.pl_devices_licence();

-- 3) existing data, once: rows for paired handhelds (with their location's licence), spares for licensed locations
--    that have no handheld
do $m$
begin
  if not exists (select 1 from public.pl_handheld_licences) then
    insert into public.pl_handheld_licences(org_id, device_id, licence_type, licence_starts_at, licence_expires_at, notes)
    select d.org_id, d.id,
           case when public.pl_lic_valid(l.licence_type, l.licence_expires_at) then l.licence_type end,
           case when public.pl_lic_valid(l.licence_type, l.licence_expires_at) then coalesce(l.licence_starts_at, now()) end,
           case when public.pl_lic_valid(l.licence_type, l.licence_expires_at) then l.licence_expires_at end,
           case when public.pl_lic_valid(l.licence_type, l.licence_expires_at) then 'Moved from the location licence (12 Nov 2026)' end
      from public.pl_devices d left join public.pl_site_licences l on l.site_id = d.site_id
    on conflict (device_id) do nothing;
    insert into public.pl_handheld_licences(org_id, device_id, licence_type, licence_starts_at, licence_expires_at, notes)
    select l.org_id, null, l.licence_type, coalesce(l.licence_starts_at, now()), l.licence_expires_at,
           'Spare: moved from the licence of location ' || coalesce(r.data->>'name', l.site_id) || ' (12 Nov 2026)'
      from public.pl_site_licences l join public.pl_records r on r.id = l.site_id and r.kind = 'sites' and not r.deleted
     where public.pl_lic_valid(l.licence_type, l.licence_expires_at)
       and not exists (select 1 from public.pl_devices d where d.site_id = l.site_id);
  end if;
end $m$;

-- 4) open / locked
create or replace function public.pl_handheld_open(p_device text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_devices d join public.pl_orgs o on o.id = d.org_id
                   join public.pl_handheld_licences l on l.device_id = d.id
                  where d.id = p_device and not o.suspended and public.pl_lic_valid(l.licence_type, l.licence_expires_at)) $$;

create or replace function public.pl_site_open(p_org text, p_site text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_records r join public.pl_orgs o on o.id = r.org_id
                  where r.id = p_site and r.kind = 'sites' and not r.deleted and r.org_id = p_org and not o.suspended) $$;

create or replace function public.pl_org_locked(p_org text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_orgs o where o.id = p_org and o.suspended) $$;

create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; d public.pl_devices; f text;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return public.pl_master_in(p_org); end if;
  d := public.pl_device_me();
  if d.id is not null then   -- a handheld: only while its own licence is valid
    if not public.pl_handheld_open(d.id) then return false; end if;
    return p_org = d.org_id and p_kind <> 'sites' and (p_site is null or p_site = d.site_id);
  end if;
  if p_site is not null and p_kind <> 'sites' then
    if not public.pl_site_open(p_org, p_site) then return false; end if;
  elsif public.pl_org_locked(p_org) then
    return false;
  end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;
  f := public.pl_write_feature(p_kind);
  if f is not null and not coalesce((m.features ->> f)::boolean, true) then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

-- 5) JSON: a location (no licence needed: reads as lifetime for older dashboards) and a handheld licence
create or replace function hub_private.pl_site_lic_json(p_site text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'name', coalesce(r.data->>'name', ''), 'per_handheld', true,
           'licence_type', 'lifetime', 'licence_starts_at', null, 'licence_expires_at', null,
           'licensed', not o.suspended, 'no_licence', false, 'expired', false, 'locked', o.suspended)
    from public.pl_records r join public.pl_orgs o on o.id = r.org_id
   where r.id = p_site and r.kind = 'sites' $$;

create or replace function hub_private.pl_hl_json(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', l.id, 'device_id', l.device_id, 'spare', l.device_id is null,
           'name', coalesce(d.name, 'Spare handheld licence'), 'site_id', d.site_id,
           'site_name', (select coalesce(r.data->>'name', '') from public.pl_records r where r.id = d.site_id and r.kind = 'sites'),
           'licence_type', l.licence_type, 'licence_starts_at', l.licence_starts_at, 'licence_expires_at', l.licence_expires_at,
           'licensed', public.pl_lic_valid(l.licence_type, l.licence_expires_at),
           'no_licence', l.licence_type is null,
           'expired', l.licence_type is not null and l.licence_type <> 'lifetime' and l.licence_expires_at <= now())
    from public.pl_handheld_licences l left join public.pl_devices d on d.id = l.device_id
   where l.id = p_id $$;
revoke all on function hub_private.pl_site_lic_json(text), hub_private.pl_hl_json(text) from public, anon, authenticated;

-- 6) set a handheld licence (master and portal). type null = remove. Same rules as 009's location licence.
create or replace function hub_private.pl_apply_hl_licence(p_id text, p_type text, p_extend boolean, p_expires timestamptz, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cur public.pl_handheld_licences; base timestamptz; new_exp timestamptz; t text := nullif(trim(coalesce(p_type, '')), '');
  nt text := nullif(trim(coalesce(p_notes, '')), '');
begin
  select * into cur from public.pl_handheld_licences where id = p_id or device_id = p_id for update;
  if cur.id is null then raise exception 'Handheld not found'; end if;
  if t is null then
    if cur.device_id is null then delete from public.pl_handheld_licences where id = cur.id;   -- an emptied spare goes
      return jsonb_build_object('id', cur.id, 'kind', 'handheld', 'license_type', null, 'removed', true); end if;
    update public.pl_handheld_licences set licence_type = null, licence_starts_at = null, licence_expires_at = null,
           notes = coalesce(nt, notes), updated_at = now() where id = cur.id;
  else
    if t = 'lifetime' then new_exp := null;
    elsif t = 'custom' then
      if p_expires is null then raise exception 'Choose an end date.'; end if;
      new_exp := p_expires;
    elsif t = 'trial' and p_expires is not null then new_exp := p_expires;
    else
      base := case when coalesce(p_extend, false) and cur.licence_type is distinct from 'lifetime' and cur.licence_expires_at > now()
                   then cur.licence_expires_at else now() end;
      new_exp := base + case t when 'trial' then interval '3 days' when 'm1' then interval '1 month' when 'm3' then interval '3 months'
        when 'm6' then interval '6 months' when 'm12' then interval '12 months' when 'm24' then interval '24 months'
        when 'm36' then interval '36 months' else null end;
      if new_exp is null then raise exception 'Unknown licence type %', t; end if;
    end if;
    update public.pl_handheld_licences set licence_type = t,
           licence_starts_at = case when coalesce(p_extend, false) and licence_starts_at is not null then licence_starts_at else now() end,
           licence_expires_at = new_exp, notes = coalesce(nt, notes), updated_at = now()
     where id = cur.id;
  end if;
  select * into cur from public.pl_handheld_licences where id = cur.id;
  return jsonb_build_object('id', cur.id, 'kind', 'handheld', 'license_type', cur.licence_type, 'starts_at', cur.licence_starts_at,
                            'expires_at', cur.licence_expires_at, 'notes', cur.notes);
end $$;
revoke all on function hub_private.pl_apply_hl_licence(text, text, boolean, timestamptz, text) from public, anon, authenticated;

-- a business's 3-day trial = one spare trial licence (the first handheld paired takes it); not if it already has any
create or replace function hub_private.pl_hl_trial(p_org text, p_notes text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e timestamptz := now() + interval '3 days'; dv text;
begin
  if not exists (select 1 from public.pl_orgs where id = p_org) then raise exception 'Business not found.'; end if;
  if exists (select 1 from public.pl_handheld_licences where org_id = p_org and licence_type is not null) then
    return jsonb_build_object('applied', false, 'expires_at', null);
  end if;
  select l.device_id into dv from public.pl_handheld_licences l where l.org_id = p_org and l.device_id is not null limit 1;
  if dv is not null then
    update public.pl_handheld_licences set licence_type = 'trial', licence_starts_at = now(), licence_expires_at = e,
           notes = p_notes, updated_at = now() where device_id = dv;
  else
    insert into public.pl_handheld_licences(org_id, licence_type, licence_starts_at, licence_expires_at, notes)
    values (p_org, 'trial', now(), e, p_notes);
  end if;
  return jsonb_build_object('applied', true, 'expires_at', e, 'license_type', 'trial');
end $$;
revoke all on function hub_private.pl_hl_trial(text, text) from public, anon, authenticated;

create or replace function public.pl_set_handheld_licence(p_id text, p_type text, p_expires timestamptz default null,
  p_extend boolean default false, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a licence.'; end if;
  return hub_private.pl_apply_hl_licence(p_id, p_type, p_extend, p_expires, p_notes);
end $$;
revoke all on function public.pl_set_handheld_licence(text, text, timestamptz, boolean, text) from public, anon;
grant execute on function public.pl_set_handheld_licence(text, text, timestamptz, boolean, text) to authenticated;

create or replace function public.pl_set_site_licence(p_site text, p_type text, p_expires timestamptz default null,
  p_extend boolean default false, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Proview Label is licensed per handheld: set the licence on the handheld (Handhelds page).';
end $$;

-- older back-office builds: the business's licence = every handheld licence of it (a spare when it has none)
create or replace function public.pl_set_licence(p_org text, p_licensed boolean, p_ends timestamptz default null) returns void
language plpgsql security definer set search_path = public as $$
declare i text; t text := case when not coalesce(p_licensed, false) then null when p_ends is null then 'lifetime' else 'trial' end;
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a licence.'; end if;
  if not exists (select 1 from public.pl_orgs where id = p_org) then raise exception 'Business not found.'; end if;
  if t is not null and not exists (select 1 from public.pl_handheld_licences where org_id = p_org) then
    insert into public.pl_handheld_licences(org_id) values (p_org);
  end if;
  for i in select id from public.pl_handheld_licences where org_id = p_org loop
    perform hub_private.pl_apply_hl_licence(i, t, false, p_ends, null);
  end loop;
end $$;

-- 7) whoami. A HANDHELD gets its own licence in the business-level fields its lock screen reads. Back-office logins:
--    the business is locked only when suspended; each business lists its handheld licences (handhelds) for the
--    Handhelds page (owners/admins/master: all, spares too; others: handhelds at their locations).
create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean; d public.pl_devices; dl jsonb; req text; lid text;
begin
  if auth.uid() is null then return null; end if;
  d := public.pl_device_me();
  if d.id is not null then
    select id into lid from public.pl_handheld_licences where device_id = d.id;
    dl := coalesce(hub_private.pl_hl_json(lid), jsonb_build_object('licensed', false, 'no_licence', true, 'expired', false));
    return jsonb_build_object('email', null, 'master', false, 'trial_used', false,
      'device', jsonb_build_object('id', d.id, 'name', d.name, 'mode', d.mode, 'site_id', d.site_id, 'org_id', d.org_id,
                                   'licence', dl),
      'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', case when (dl->>'expired')::boolean then dl->>'licence_expires_at' end,
                 'trial_expired', coalesce((dl->>'expired')::boolean, false),
                 'licensed', not coalesce((dl->>'no_licence')::boolean, true), 'no_licence', coalesce((dl->>'no_licence')::boolean, true),
                 'locked', o.suspended or not public.pl_handheld_open(d.id),
                 'sites', jsonb_build_array(dl || jsonb_build_object('id', d.site_id, 'licence_id', dl->>'id',
                                                                      'locked', o.suspended or not public.pl_handheld_open(d.id))),
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
                 'trial_ends_at', null, 'trial_expired', false, 'licensed', true, 'no_licence', false,
                 'locked', o.suspended, 'per_handheld', true,
                 'sites', coalesce((select jsonb_agg(hub_private.pl_site_lic_json(r.id) order by lower(coalesce(r.data->>'name', '')))
                                      from public.pl_records r where r.org_id = o.id and r.kind = 'sites' and not r.deleted
                                       and (is_m or m.role in ('owner','admin') or r.id = any(coalesce(m.site_ids, '{}')))), '[]'::jsonb),
                 'handhelds', coalesce((select jsonb_agg(hub_private.pl_hl_json(l.id) order by l.device_id is null, l.id)
                                      from public.pl_handheld_licences l left join public.pl_devices dv on dv.id = l.device_id
                                     where l.org_id = o.id
                                       and (is_m or m.role in ('owner','admin') or dv.site_id = any(coalesce(m.site_ids, '{}')))), '[]'::jsonb),
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               where (is_m and req is not null and o.id = req) or (not is_m and m.id is not null)), '[]'::jsonb));
end $$;

-- 8) licence portal
create or replace function hub_private.hub_call_base(p_token text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare k text := nullif(p_args->>'kind', '');
begin
  if p_token is null or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  if p_action = 'list' then
    return jsonb_build_object(
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name,
                    'contact_email', (select lower(m.email) from public.pl_members m where m.org_id = o.id and m.role in ('owner', 'manager')
                                       order by m.role = 'owner' desc, m.created_at limit 1),
                    'created_at', o.created_at, 'self_signup', o.trial_email is not null, 'suspended', o.suspended)
                  order by lower(o.name)) from public.pl_orgs o), '[]'::jsonb),
      'units', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', 'handheld', 'account_id', l.org_id,
                    'name', coalesce(d.name, 'Spare handheld licence'),
                    'detail', case when d.id is null then 'Not paired: the next handheld paired takes it'
                                   else coalesce((select r.data->>'name' from public.pl_records r where r.id = d.site_id and r.kind = 'sites'), '') end,
                    'location_id', d.site_id,
                    'license_type', l.licence_type, 'starts_at', l.licence_starts_at, 'expires_at', l.licence_expires_at,
                    'notes', l.notes, 'last_seen', null, 'archived', false)
                  order by l.org_id, l.device_id is null, lower(coalesce(d.name, '')), l.id)
                  from public.pl_handheld_licences l left join public.pl_devices d on d.id = l.device_id), '[]'::jsonb));
  elsif p_action = 'set' then
    if k is not null and k <> 'handheld' then raise exception 'Proview Label is licensed per handheld (kind %).', k; end if;
    return hub_private.pl_apply_hl_licence(p_args->>'unit', nullif(p_args->>'type', ''), coalesce((p_args->>'extend')::boolean, false),
                                           nullif(p_args->>'expires', '')::timestamptz, p_args->>'notes');
  elsif p_action = 'trial' then
    return hub_private.pl_hl_trial(coalesce(p_args->>'account_id', ''), coalesce(nullif(trim(p_args->>'notes'), ''), '3-day trial'))
           || jsonb_build_object('account_id', p_args->>'account_id');
  elsif p_action = 'link' then
    return hub_private.pl_link_orgs(p_args->>'into', p_args->>'from');
  elsif p_action = 'unlink' then
    -- the portal may name a location by one of its handheld licence units ('hl_…'): use that handheld's location
    return hub_private.pl_unlink_site(p_args->>'account', coalesce(
      (select d.site_id from public.pl_handheld_licences l join public.pl_devices d on d.id = l.device_id
        where l.id = coalesce(p_args->>'site', p_args->>'unit', '')),
      regexp_replace(coalesce(p_args->>'site', p_args->>'unit', ''), '^loc/', '')));
  else
    raise exception 'unknown action %', p_action;
  end if;
end $$;
revoke all on function hub_private.hub_call_base(text, text, jsonb) from public, anon, authenticated;

-- 9) linking two businesses (011) also moves their handheld licences (spares included)
do $l$ declare d text; begin
  d := pg_get_functiondef('hub_private.pl_link_orgs(text,text)'::regprocedure);
  if position('pl_handheld_licences' in d) = 0 then
    execute replace(d, 'update public.pl_site_licences set org_id = a.id, updated_at = now() where org_id = b.id;',
      'update public.pl_site_licences set org_id = a.id, updated_at = now() where org_id = b.id;
  update public.pl_handheld_licences set org_id = a.id, updated_at = now() where org_id = b.id;');
  end if;
end $l$;
