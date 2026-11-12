-- 011: locations, not customers. Only the master links them (owner, 12 Nov 2026, LOCATIONS_LINK_SPEC.md; hub contract
-- LOCATIONS_LINK_PROTOCOL.md).
--
-- A business (pl_orgs) holds 1..N locations (pl_records kind 'sites'). From now on:
--   * nobody adds or deletes a location in the app: not owners, admins, managers, nor the master inside a business.
--     The only new locations are the FIRST location of a brand-new business, made in the same transaction as the
--     business (pl_add_business = the licence portal's New location via hub 'add_business', and pl_start_trial =
--     the free self sign-up). A location's settings (name, address, area) stay editable as before.
--   * the licence portal (hub token only) links and unlinks locations:
--       hub_call(token, 'link',   {into: A, from: B}) -> {ok, account: A, from: B, moved_sites: [site ids], already, renamed_units: []}
--         merges business B into A in one transaction: every record (locations, menu, staff, labels, wastage,
--         orders, audit), the handhelds and their pairings, the location licences and the members move to A; a person
--         in both keeps the higher role; owners, admins and managers of either side get every location of the merged
--         business (device staff keep exactly their locations); B's settings fill in what A has not set; B is deleted.
--         Idempotent: B already merged into A returns the same answer with already: true.
--       hub_call(token, 'unlink', {account: A, site: S}) -> {ok, account: N, from: A, site: S, already, renamed_units: []}
--         moves location S out of A into a new business N named after the location: S, its records (labels,
--         wastage, orders, device records), handhelds, pairings and licence move; the menu (categories, products,
--         rules) is COPIED (new ids, references re-pointed in the copies and in S's labels / wastage); device staff
--         (PINs, always tied to locations) only at S move, staff at S and elsewhere are copied to N for S only; logins
--         are copied (owners / admins as they are, managers of S with S only) and A keeps them (S removed from A's
--         managers). Refused when S is A's only location. Idempotent: S already moved out of A returns the same
--         answer with already: true. Location ids never change, so renamed_units is always [].
--     Both are logged in hub_private.location_links.
--   * licences stay per location (pl_site_licences, 009): they move with their location, nothing else changes.
-- Unchanged: 'list', 'set', 'add_business', the master-open scoping (010), every read rule.
-- Safe to run more than once.

-- 1) log of links and unlinks (idempotency, and the record of what moved)
create table if not exists hub_private.location_links(
  id bigint generated always as identity primary key,
  action text not null check (action in ('link', 'unlink')),
  from_account text not null,
  into_account text not null,
  site_id text,
  moved_sites jsonb not null default '[]'::jsonb,
  at timestamptz not null default now());
create index if not exists location_links_from on hub_private.location_links(action, from_account);
revoke all on table hub_private.location_links from public, anon, authenticated;

-- 2) no adding or deleting locations except through the hub (or a brand-new business's first location)
-- Runs as the caller (not SECURITY DEFINER): a signed-in person's request runs as role authenticated, so the hub flag
-- (set only inside the hub's SECURITY DEFINER link / unlink) never counts for them, and the checks below only see the
-- rows that person may see.
create or replace function public.pl_sites_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('pl.hub_move', true), '') = '1' and current_user not in ('anon', 'authenticated') then
    return new;                                                                        -- hub link / unlink
  end if;
  if tg_op = 'INSERT' then
    if new.kind <> 'sites' then return new; end if;
    -- an upsert of a location that already exists is an edit (the UPDATE trigger checks it)
    if exists (select 1 from public.pl_records r where r.id = new.id) then return new; end if;
    -- the first location of a business created in this same transaction (New location in the portal, self sign-up)
    if exists (select 1 from public.pl_orgs o where o.id = new.org_id and o.created_at = now())
       and not exists (select 1 from public.pl_records r where r.org_id = new.org_id and r.kind = 'sites') then
      return new;
    end if;
    raise exception 'New locations are added by Proview in the licence portal.' using errcode = '42501';
  end if;
  -- UPDATE
  if old.kind = 'sites' or new.kind = 'sites' then
    if new.kind is distinct from old.kind or new.org_id is distinct from old.org_id or new.site_id is distinct from old.site_id then
      raise exception 'A location can''t be moved to another business here. Proview links locations in the licence portal.' using errcode = '42501';
    end if;
    if new.deleted and not old.deleted then
      raise exception 'Locations can''t be deleted here. Proview unlinks locations in the licence portal.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.pl_sites_guard() from public, anon, authenticated;
drop trigger if exists pl_sites_guard on public.pl_records;
create trigger pl_sites_guard before insert or update on public.pl_records for each row execute function public.pl_sites_guard();

-- 3) link: merge business p_from into p_into
create or replace function hub_private.pl_link_orgs(p_into text, p_from text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.pl_orgs; b public.pl_orgs; lg hub_private.location_links; moved jsonb; a_sites text[]; b_sites text[];
  rk constant jsonb := '{"owner":3,"admin":2,"manager":1}';
  bm public.pl_members; am public.pl_members;
begin
  if coalesce(trim(p_into), '') = '' or coalesce(trim(p_from), '') = '' then raise exception 'link needs into and from.'; end if;
  if p_into = p_from then raise exception 'An account can''t be linked to itself.'; end if;
  select * into a from public.pl_orgs where id = p_into for update;
  select * into b from public.pl_orgs where id = p_from for update;
  if b.id is null then
    select * into lg from hub_private.location_links where action = 'link' and from_account = p_from order by id desc limit 1;
    if lg.id is not null and lg.into_account <> p_into then
      raise exception '% was already linked into %, not %.', p_from, lg.into_account, p_into;
    end if;
    if lg.id is not null and a.id is not null then
      return jsonb_build_object('ok', true, 'account', p_into, 'from', p_from, 'moved_sites', lg.moved_sites, 'already', true,
                                'renamed_units', '[]'::jsonb);
    end if;
    raise exception 'Account not found: %', case when a.id is null then p_into else p_from end;
  end if;
  if a.id is null then raise exception 'Account not found: %', p_into; end if;

  perform set_config('pl.hub_move', '1', true);
  select coalesce(array_agg(id order by id), '{}') into a_sites from public.pl_records where org_id = a.id and kind = 'sites' and not deleted;
  select coalesce(array_agg(id order by id), '{}') into b_sites from public.pl_records where org_id = b.id and kind = 'sites' and not deleted;
  moved := to_jsonb(b_sites);

  -- every record, the handhelds, pairings, licences and the free-trial marker
  update public.pl_records set org_id = a.id, data = jsonb_set(data, '{orgId}', to_jsonb(a.id), true) where org_id = b.id;
  update public.pl_devices set org_id = a.id where org_id = b.id;
  update public.pl_pairings set org_id = a.id where org_id = b.id;
  update public.pl_site_licences set org_id = a.id, updated_at = now() where org_id = b.id;
  update public.pl_trials set org_id = a.id where org_id = b.id;

  -- members: someone in both keeps the higher role; owners, admins and managers of either side get every location
  -- of the merged business (owners and admins see them all anyway; managers get them in site_ids)
  update public.pl_members m set site_ids = (select coalesce(array_agg(distinct x order by x), '{}') from unnest(m.site_ids || a_sites || b_sites) x)
   where m.org_id = a.id and m.role = 'manager';
  for bm in select * from public.pl_members where org_id = b.id loop
    select * into am from public.pl_members where org_id = a.id and email = bm.email;
    if am.id is not null then
      update public.pl_members set
        role = case when (rk->>bm.role)::int > (rk->>am.role)::int then bm.role else am.role end,
        site_ids = (select coalesce(array_agg(distinct x order by x), '{}') from unnest(am.site_ids || bm.site_ids || a_sites || b_sites) x),
        user_id = coalesce(am.user_id, bm.user_id),
        name = coalesce(nullif(am.name, ''), bm.name),
        mobile = coalesce(am.mobile, bm.mobile)
       where id = am.id;
      delete from public.pl_members where id = bm.id;
    else
      update public.pl_members set org_id = a.id,
        site_ids = case when bm.role = 'manager' then (select coalesce(array_agg(distinct x order by x), '{}') from unnest(bm.site_ids || a_sites || b_sites) x) else site_ids end
       where id = bm.id;
    end if;
  end loop;

  update public.pl_orgs set settings = coalesce(b.settings, '{}'::jsonb) || coalesce(a.settings, '{}'::jsonb) where id = a.id;
  delete from public.pl_orgs where id = b.id;
  insert into hub_private.location_links(action, from_account, into_account, moved_sites) values ('link', b.id, a.id, moved);
  perform set_config('pl.hub_move', '', true);
  return jsonb_build_object('ok', true, 'account', a.id, 'from', b.id, 'moved_sites', moved, 'already', false, 'renamed_units', '[]'::jsonb);
end $$;
revoke all on function hub_private.pl_link_orgs(text, text) from public, anon, authenticated;

-- 4) unlink: move location p_site out of business p_org into a new business of its own
create or replace function hub_private.pl_unlink_site(p_org text, p_site text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.pl_orgs; s public.pl_records; lg hub_private.location_links; nid text; sfx text; n_sites int;
  idmap jsonb := '{}'::jsonb; r record; nm text;
begin
  if coalesce(trim(p_org), '') = '' or coalesce(trim(p_site), '') = '' then raise exception 'unlink needs account and site.'; end if;
  select * into a from public.pl_orgs where id = p_org for update;
  select * into s from public.pl_records where id = p_site and kind = 'sites' and not deleted;
  if a.id is null or s.id is null or s.org_id <> a.id then
    select * into lg from hub_private.location_links where action = 'unlink' and from_account = p_org and site_id = p_site order by id desc limit 1;
    if lg.id is not null and exists (select 1 from public.pl_records where id = p_site and org_id = lg.into_account and kind = 'sites' and not deleted) then
      return jsonb_build_object('ok', true, 'account', lg.into_account, 'from', p_org, 'site', p_site, 'already', true, 'renamed_units', '[]'::jsonb);
    end if;
    if a.id is null then raise exception 'Account not found: %', p_org; end if;
    if s.id is null then raise exception 'Location not found: %', p_site; end if;
    raise exception 'That location is not in account %.', p_org;
  end if;
  select count(*) into n_sites from public.pl_records where org_id = a.id and kind = 'sites' and not deleted;
  if n_sites < 2 then raise exception '% has only that one location, so there is nothing to unlink.', a.name; end if;

  perform set_config('pl.hub_move', '1', true);
  nm := left(coalesce(nullif(trim(s.data->>'name'), ''), a.name), 120);
  insert into public.pl_orgs(name, settings, suspended, licensed) values (nm, a.settings, a.suspended, a.licensed) returning id into nid;
  sfx := substr(md5(nid), 1, 8);

  -- the location and everything recorded at it
  update public.pl_records set org_id = nid, data = jsonb_set(data, '{orgId}', to_jsonb(nid), true) where org_id = a.id and site_id = s.id;
  update public.pl_devices set org_id = nid where org_id = a.id and site_id = s.id;
  update public.pl_pairings set org_id = nid where org_id = a.id and site_id = s.id;
  update public.pl_site_licences set org_id = nid, updated_at = now() where site_id = s.id;

  -- the menu is shared by the business's locations: copy it (rules, categories, products) with new ids
  for r in select id from public.pl_records where org_id = a.id and site_id is null and kind in ('rules', 'categories', 'products') and not deleted loop
    idmap := idmap || jsonb_build_object(r.id, r.id || '_' || sfx);
  end loop;
  insert into public.pl_records(id, org_id, site_id, kind, data)
    select idmap->>x.id, nid, null, x.kind,
           x.data || jsonb_build_object('id', idmap->>x.id, 'orgId', nid)
                  || case when idmap ? (x.data->>'categoryId') then jsonb_build_object('categoryId', idmap->>(x.data->>'categoryId')) else '{}'::jsonb end
                  || case when idmap ? (x.data->>'ruleId') then jsonb_build_object('ruleId', idmap->>(x.data->>'ruleId')) else '{}'::jsonb end
      from public.pl_records x where x.org_id = a.id and idmap ? x.id;
  update public.pl_records set data = data || jsonb_build_object('productId', idmap->>(data->>'productId'))
   where org_id = nid and site_id = s.id and idmap ? (data->>'productId');

  -- device staff (PINs): only at this location -> move; here and elsewhere -> a copy for this location
  update public.pl_records set org_id = nid, data = data || jsonb_build_object('orgId', nid)
   where org_id = a.id and kind = 'users' and site_id is null and jsonb_typeof(data->'siteIds') = 'array'
     and data->'siteIds' = jsonb_build_array(s.id);
  insert into public.pl_records(id, org_id, site_id, kind, data, deleted)
    select x.id || '_' || sfx, nid, null, 'users',
           x.data || jsonb_build_object('id', x.id || '_' || sfx, 'orgId', nid, 'siteIds', jsonb_build_array(s.id)), x.deleted
      from public.pl_records x where x.org_id = a.id and x.kind = 'users' and x.site_id is null
       and jsonb_typeof(x.data->'siteIds') = 'array' and x.data->'siteIds' ? s.id;
  update public.pl_records set data = data || jsonb_build_object('siteIds',
           coalesce((select jsonb_agg(e) from jsonb_array_elements(data->'siteIds') e where e <> to_jsonb(s.id)), '[]'::jsonb))
   where org_id = a.id and kind = 'users' and site_id is null and jsonb_typeof(data->'siteIds') = 'array' and data->'siteIds' ? s.id;

  -- logins: copied, A keeps them too (owners and admins as they are; managers of this location with it only)
  insert into public.pl_members(org_id, email, user_id, name, mobile, role, site_ids, features)
    select nid, m.email, m.user_id, m.name, m.mobile, m.role,
           case when m.role = 'manager' then array[s.id] else '{}'::text[] end, m.features
      from public.pl_members m where m.org_id = a.id and (m.role <> 'manager' or s.id = any(m.site_ids));
  update public.pl_members set site_ids = array_remove(site_ids, s.id) where org_id = a.id and role = 'manager' and s.id = any(site_ids);

  insert into hub_private.location_links(action, from_account, into_account, site_id, moved_sites)
    values ('unlink', a.id, nid, s.id, jsonb_build_array(s.id));
  perform set_config('pl.hub_move', '', true);
  return jsonb_build_object('ok', true, 'account', nid, 'from', a.id, 'site', s.id, 'already', false, 'renamed_units', '[]'::jsonb);
end $$;
revoke all on function hub_private.pl_unlink_site(text, text) from public, anon, authenticated;

-- 5) the hub: 'link' and 'unlink' added; 'list', 'set' exactly as 009 ('add_business' stays in public.hub_call, 008)
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
      'units', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'kind', 'location', 'account_id', r.org_id,
                    'name', coalesce(r.data->>'name', ''), 'detail', o.name,
                    'license_type', l.licence_type, 'starts_at', l.licence_starts_at, 'expires_at', l.licence_expires_at,
                    'notes', l.notes, 'last_seen', null, 'archived', false)
                  order by lower(coalesce(r.data->>'name', '')), r.id)
                  from public.pl_records r join public.pl_orgs o on o.id = r.org_id
                  left join public.pl_site_licences l on l.site_id = r.id
                 where r.kind = 'sites' and not r.deleted), '[]'::jsonb));
  elsif p_action = 'set' then
    if k is not null and k <> 'location' then raise exception 'Proview Label only has location licences (kind %).', k; end if;
    return hub_private.pl_apply_site_licence(p_args->>'unit', nullif(p_args->>'type', ''), coalesce((p_args->>'extend')::boolean, false),
                                             nullif(p_args->>'expires', '')::timestamptz, p_args->>'notes');
  elsif p_action = 'link' then
    return hub_private.pl_link_orgs(p_args->>'into', p_args->>'from');
  elsif p_action = 'unlink' then
    return hub_private.pl_unlink_site(p_args->>'account', regexp_replace(coalesce(p_args->>'site', p_args->>'unit', ''), '^loc/', ''));
  else
    raise exception 'unknown action %', p_action;
  end if;
end $$;
revoke all on function hub_private.hub_call_base(text, text, jsonb) from public, anon, authenticated;
