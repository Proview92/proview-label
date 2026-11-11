-- Tests for supabase/migrations/009_location_licences.sql. Run as ONE query: the setup block, then the migration, then
-- the test block. It is all one transaction that always fails at the end (the PASS/FAIL report is the error message),
-- so nothing is kept. Build it with:
--   { sed -n '/^-- SETUP/,/^-- END SETUP/p' tests/009_location_licences_test.sql; cat supabase/migrations/009_location_licences.sql; sed -n '/^-- TESTS/,$p' tests/009_location_licences_test.sql; }

-- SETUP (runs on the functions as they are BEFORE 009): remember what every existing member and handheld could do
do $S$
begin
  create or replace function pg_temp.as_(uid uuid, org text default null) returns void language plpgsql as $f$
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', uid::text, true);
    perform set_config('request.headers', case when org is null then '{}' else json_build_object('x-pl-org', org)::text end, true);
    execute 'set local role authenticated';
  end $f$;
  create or replace function pg_temp.anon_() returns void language plpgsql as $f$
  begin
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.headers', '{}', true);
    execute 'set local role anon';
  end $f$;
  create or replace function pg_temp.svc() returns void language plpgsql as $f$
  begin
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.headers', '{}', true);
  end $f$;
  -- every (person or handheld, location, kind) write answer before 009
  create temp table t_before(uid uuid, who text, org text, site text, kind text, can boolean, locked boolean);
  insert into t_before(uid, who, org, site, kind)
    select m.user_id, 'member ' || m.role, m.org_id, r.id, k
      from public.pl_members m join public.pl_records r on r.org_id = m.org_id and r.kind = 'sites' and not r.deleted
      cross join unnest(array['labels', 'products', 'devices']) k where m.user_id is not null
    union all
    select d.user_id, 'handheld', d.org_id, d.site_id, k from public.pl_devices d cross join unnest(array['labels', 'products']) k where d.user_id is not null;
  grant all on t_before to authenticated;
  declare r record; begin
    for r in select distinct uid from t_before loop
      perform pg_temp.as_(r.uid);
      update t_before t set can = public.pl_can_write(t.org, t.site, t.kind) where t.uid = r.uid;
      update t_before t set locked = (select (z->>'locked')::boolean from jsonb_array_elements(public.pl_whoami()->'orgs') z where z->>'id' = t.org) where t.uid = r.uid;
      perform pg_temp.svc();
    end loop;
  end;
  create temp table t_orgs_before as select id, licensed, trial_ends_at, suspended from public.pl_orgs;
end $S$;
-- END SETUP

-- (the migration goes here)

-- TESTS
do $T$
declare
  master uuid := (select user_id from public.pl_masters order by added_at limit 1);
  u_own  uuid := 'a0090000-0000-4000-8000-000000000001';
  u_dev1 uuid := 'a0090000-0000-4000-8000-000000000002';
  u_dev2 uuid := 'a0090000-0000-4000-8000-000000000003';
  tok text := 'pl009-test-token';
  mk text; out text := ''; r jsonb; w jsonb; o jsonb; e text; n int; n2 int; b boolean; oid text; s1 text; s2 text; t timestamptz;
begin
  if master is null then raise exception 'no master'; end if;
  update hub_private.config set token_sha256 = encode(extensions.digest(tok, 'sha256'), 'hex') where id = 1;   -- test token (rolled back)

  -- 1. existing businesses: their live locations are lifetime and nothing anyone could do has changed
  select count(*) into n from public.pl_records r join t_orgs_before o on o.id = r.org_id where r.kind = 'sites' and not r.deleted and o.licensed and o.trial_ends_at is null;
  select count(*) into n2 from public.pl_site_licences l join t_orgs_before o on o.id = l.org_id where l.licence_type = 'lifetime';
  out := out || format(E'\n%s existing: %s live location(s) of %s licensed business(es) are lifetime (%s rows)', case when n = n2 and n > 0 then 'PASS' else 'FAIL' end,
                       n, (select count(*) from t_orgs_before where licensed and not suspended), n2);
  select count(*) into n from t_orgs_before o where o.licensed and not o.suspended and public.pl_org_locked(o.id);
  out := out || format(E'\n%s existing: no licensed business is locked (%s locked)', case when n = 0 then 'PASS' else 'FAIL' end, n);
  declare rr record; begin
    for rr in select distinct uid from t_before loop
      perform pg_temp.as_(rr.uid);
      update t_before t set can = (t.can is not distinct from public.pl_can_write(t.org, t.site, t.kind)),
                            locked = (t.locked is not distinct from (select (z->>'locked')::boolean from jsonb_array_elements(public.pl_whoami()->'orgs') z where z->>'id' = t.org))
       where t.uid = rr.uid;
      perform pg_temp.svc();
    end loop;
  end;
  select count(*), count(*) filter (where can and locked) into n, n2 from t_before;
  out := out || format(E'\n%s existing members and handhelds: every write answer and lock state is the same as before (%s of %s checks)',
                       case when n = n2 then 'PASS' else 'FAIL' end, n2, n);

  -- 2. hub: wrong / missing token refused; right token lists one unit per location
  perform pg_temp.anon_();
  begin r := public.hub_call('wrong', 'list', '{}'); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub list, wrong token: refused (%s)', case when e = 'not authorised' then 'PASS' else 'FAIL' end, e);
  begin r := public.hub_call(null, 'list', '{}'); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub list, no token: refused (%s)', case when e = 'not authorised' then 'PASS' else 'FAIL' end, e);
  begin r := public.hub_call('wrong', 'set', jsonb_build_object('unit', 'x', 'type', 'm12')); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub set, wrong token: refused (%s)', case when e = 'not authorised' then 'PASS' else 'FAIL' end, e);
  r := public.hub_call(tok, 'list', '{}');
  perform pg_temp.svc();
  select count(*) into n from public.pl_records where kind = 'sites' and not deleted;
  b := jsonb_array_length(r->'units') = n and not exists (select 1 from jsonb_array_elements(r->'units') u where u->>'kind' <> 'location' or u->>'account_id' is null)
       and jsonb_array_length(r->'accounts') = (select count(*) from public.pl_orgs);
  out := out || format(E'\n%s hub list: %s location unit(s), kind location, account_id = business; %s account(s)', case when b then 'PASS' else 'FAIL' end,
                       jsonb_array_length(r->'units'), jsonb_array_length(r->'accounts'));
  b := not exists (select 1 from jsonb_array_elements(r->'units') u join t_orgs_before o on o.id = u->>'account_id' where o.licensed and o.trial_ends_at is null and u->>'license_type' is distinct from 'lifetime');
  out := out || format(E'\n%s hub list: existing locations read as lifetime', case when b then 'PASS' else 'FAIL' end);

  -- 3. a new business (master + Add business, which the portal's add_business also runs): no licence, locked
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (u_dev1, 'pl009-dev1@test.invalid', 'authenticated', 'authenticated', now()),
    (u_dev2, 'pl009-dev2@test.invalid', 'authenticated', 'authenticated', now());
  perform pg_temp.as_(master);
  r := public.pl_add_business('PL009 Cafe', 'Sam Taylor', 'pl009-owner@test.invalid', '', 'secret12');
  perform pg_temp.svc();
  oid := r->>'org_id'; s1 := r->>'site_id'; u_own := (r->>'user_id')::uuid;
  out := out || format(E'\n%s new business: its location has no licence and is locked', case when not public.pl_site_open(oid, s1) and public.pl_org_locked(oid)
                       and not exists (select 1 from public.pl_site_licences where site_id = s1 and licence_type is not null) then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(u_own);
  b := public.pl_can_write(oid, s1, 'labels'); w := public.pl_whoami();
  perform pg_temp.svc();
  o := (select x from jsonb_array_elements(w->'orgs') x where x->>'id' = oid);
  out := out || format(E'\n%s new business: owner can''t write, whoami locked / no_licence, location no_licence', case when not b and (o->>'locked')::boolean
                       and (o->>'no_licence')::boolean and (o->'sites'->0->>'no_licence')::boolean and (o->'sites'->0->>'locked')::boolean then 'PASS' else 'FAIL' end);

  -- 4. non-master can't set a licence
  perform pg_temp.as_(u_own);
  begin perform public.pl_set_site_licence(s1, 'lifetime'); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s owner: pl_set_site_licence refused (%s)', case when e like 'Only a Proview master%' then 'PASS' else 'FAIL' end, e);
  begin perform public.pl_set_licence(oid, true, null); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s owner: old pl_set_licence refused (%s)', case when e like 'Only a Proview master%' then 'PASS' else 'FAIL' end, e);
  begin insert into public.pl_site_licences(site_id, org_id, licence_type) values (s1, oid, 'lifetime'); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s owner: writing pl_site_licences directly refused (%s)', case when e like 'permission denied%' then 'PASS' else 'FAIL' end, e);
  begin update public.pl_records set data = data || '{"licence_type":"lifetime"}' where id = s1; e := 'no effect'; exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s owner: a licence written into the location record does nothing (%s)', case when not public.pl_site_open(oid, s1) then 'PASS' else 'FAIL' end, e);
  perform pg_temp.anon_();
  begin r := public.hub_call('wrong', 'set', jsonb_build_object('unit', s1, 'type', 'm12')); e := 'allowed'; exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s anon, wrong token: set refused, still locked (%s)', case when e = 'not authorised' and not public.pl_site_open(oid, s1) then 'PASS' else 'FAIL' end, e);

  -- 5. portal sets m12: the location opens
  perform pg_temp.anon_();
  r := public.hub_call(tok, 'set', jsonb_build_object('unit', s1, 'kind', 'location', 'type', 'm12', 'extend', true, 'notes', 'Paid online'));
  perform pg_temp.svc();
  b := r->>'license_type' = 'm12' and abs(extract(epoch from ((r->>'expires_at')::timestamptz - (now() + interval '12 months')))) < 60 and r->>'kind' = 'location';
  out := out || format(E'\n%s hub set m12: returns m12 ending in 12 months (%s)', case when b then 'PASS' else 'FAIL' end, r);
  perform pg_temp.as_(u_own);
  b := public.pl_can_write(oid, s1, 'labels') and public.pl_can_write(oid, null, 'products'); w := public.pl_whoami();
  perform pg_temp.svc();
  o := (select x from jsonb_array_elements(w->'orgs') x where x->>'id' = oid);
  out := out || format(E'\n%s after m12: unlocked, owner can write; whoami licensed', case when b and public.pl_site_open(oid, s1) and not (o->>'locked')::boolean
                       and (o->>'licensed')::boolean and (o->'sites'->0->>'licensed')::boolean then 'PASS' else 'FAIL' end);
  -- extend adds on top of the running licence
  perform pg_temp.anon_();
  r := public.hub_call(tok, 'set', jsonb_build_object('unit', s1, 'type', 'm1', 'extend', true));
  perform pg_temp.svc();
  b := abs(extract(epoch from ((r->>'expires_at')::timestamptz - (now() + interval '12 months' + interval '1 month')))) < 60;
  out := out || format(E'\n%s hub set m1 extend: added to the end (%s)', case when b then 'PASS' else 'FAIL' end, r->>'expires_at');
  perform pg_temp.anon_();
  begin r := public.hub_call(tok, 'set', jsonb_build_object('unit', s1, 'kind', 'screen', 'type', 'm1')); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub set kind screen: refused (%s)', case when e like '%only has location%' then 'PASS' else 'FAIL' end, e);
  begin r := public.hub_call(tok, 'set', jsonb_build_object('unit', 'site_nope', 'type', 'm1')); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub set unknown location: refused (%s)', case when e = 'Location not found' then 'PASS' else 'FAIL' end, e);
  begin r := public.hub_call(tok, 'set', jsonb_build_object('unit', s1, 'type', 'custom')); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub set custom without a date: refused (%s)', case when e = 'Choose an end date.' then 'PASS' else 'FAIL' end, e);
  begin r := public.hub_call(tok, 'set', jsonb_build_object('unit', s1, 'type', 'm99')); e := 'allowed'; exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s hub set unknown type: refused (%s)', case when e like 'Unknown licence type%' then 'PASS' else 'FAIL' end, e);

  -- 6. a second location: the owner can add it (business has an open location); it starts with no licence and is locked
  s2 := 'site_pl009second';
  perform pg_temp.as_(u_own);
  insert into public.pl_records(id, org_id, site_id, kind, data) values (s2, oid, s2, 'sites', jsonb_build_object('id', s2, 'orgId', oid, 'name', 'PL009 Second'));
  b := public.pl_can_write(oid, s2, 'labels');
  perform pg_temp.svc();
  out := out || format(E'\n%s new location: added by the owner, no licence, locked; the first stays open', case when not b and not public.pl_site_open(oid, s2)
                       and public.pl_site_open(oid, s1) and not public.pl_org_locked(oid) then 'PASS' else 'FAIL' end);
  -- handhelds: one at each location
  insert into public.pl_devices(id, user_id, org_id, site_id, name) values ('dev_pl009a', u_dev1, oid, s1, 'A'), ('dev_pl009b', u_dev2, oid, s2, 'B');
  perform pg_temp.as_(u_dev1); w := public.pl_whoami(); b := public.pl_can_write(oid, s1, 'labels'); perform pg_temp.svc();
  out := out || format(E'\n%s handheld at the licensed location: not locked, can write', case when not (w->'orgs'->0->>'locked')::boolean and b then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(u_dev2); w := public.pl_whoami(); b := public.pl_can_write(oid, s2, 'labels') or public.pl_can_write(oid, null, 'labels'); perform pg_temp.svc();
  out := out || format(E'\n%s handheld at the unlicensed location: locked ("No licence yet"), can''t write', case when (w->'orgs'->0->>'locked')::boolean
                       and (w->'orgs'->0->>'no_licence')::boolean and not b then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(u_own);
  b := public.pl_can_write(oid, s2, 'devices');
  perform pg_temp.svc();
  out := out || format(E'\n%s pairing a handheld at the unlicensed location: refused (pl_pair_claim checks pl_can_write devices)', case when not b then 'PASS' else 'FAIL' end);

  -- 7. master's Licence… on the second location
  perform pg_temp.as_(master);
  r := public.pl_set_site_licence(s2, 'trial', (now() + interval '2 days'));
  perform pg_temp.svc();
  out := out || format(E'\n%s master: trial by hand on location 2 opens it until the date', case when r->>'license_type' = 'trial' and public.pl_site_open(oid, s2) then 'PASS' else 'FAIL' end);

  -- 8. expiry locks: location 1 ended yesterday (custom date in the past)
  perform pg_temp.anon_();
  r := public.hub_call(tok, 'set', jsonb_build_object('unit', s1, 'type', 'custom', 'expires', (now() - interval '1 day')::text));
  perform pg_temp.svc();
  perform pg_temp.as_(u_own); b := public.pl_can_write(oid, s1, 'labels'); w := public.pl_whoami(); perform pg_temp.svc();
  o := (select x from jsonb_array_elements(w->'orgs') x where x->>'id' = oid);
  out := out || format(E'\n%s expiry: location 1 ended -> locked, owner can''t write there, whoami expired; location 2 still open', case when not b and not public.pl_site_open(oid, s1)
                       and (select (x->>'expired')::boolean and (x->>'locked')::boolean from jsonb_array_elements(o->'sites') x where x->>'id' = s1)
                       and public.pl_site_open(oid, s2) and not (o->>'locked')::boolean then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(u_dev1); w := public.pl_whoami(); perform pg_temp.svc();
  out := out || format(E'\n%s expiry: the handheld at location 1 locks (reads as ended)', case when (w->'orgs'->0->>'locked')::boolean and (w->'orgs'->0->>'trial_expired')::boolean then 'PASS' else 'FAIL' end);
  update public.pl_site_licences set licence_expires_at = now() - interval '1 minute' where site_id = s2;
  perform pg_temp.as_(u_own); w := public.pl_whoami(); b := public.pl_can_write(oid, null, 'products'); perform pg_temp.svc();
  o := (select x from jsonb_array_elements(w->'orgs') x where x->>'id' = oid);
  out := out || format(E'\n%s both ended: business locked, business-wide writes refused, older builds read "ended"', case when public.pl_org_locked(oid) and not b
                       and (o->>'locked')::boolean and (o->>'trial_expired')::boolean and not (o->>'no_licence')::boolean then 'PASS' else 'FAIL' end);

  -- 9. older back-office: pl_set_licence(org) applies to every location
  perform pg_temp.as_(master); perform public.pl_set_licence(oid, true, null); perform pg_temp.svc();
  out := out || format(E'\n%s old pl_set_licence(true): every location lifetime', case when (select count(*) from public.pl_site_licences where org_id = oid and licence_type = 'lifetime') = 2 then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(master); perform public.pl_set_licence(oid, false, null); perform pg_temp.svc();
  out := out || format(E'\n%s old pl_set_licence(false): every location no licence', case when public.pl_org_locked(oid) and not public.pl_site_open(oid, s1) and not public.pl_site_open(oid, s2) then 'PASS' else 'FAIL' end);

  -- 10. hub_plans: wrong token refused; right token stored; owners read them (pl_plans)
  perform pg_temp.anon_();
  begin r := public.hub_plans('wrong', '{"m12":{"label":"12 months","amount":9900}}'); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s hub_plans, wrong token: refused (%s)', case when e = 'not authorised' then 'PASS' else 'FAIL' end, e);
  r := public.hub_plans(tok, '{"m12":{"label":"12 months","amount":9900,"currency":"gbp","link":"https://buy.stripe.com/test","ref":"pvl","kind":"location","plan":"m12"}}');
  perform pg_temp.svc();
  perform pg_temp.as_(u_own); w := public.pl_plans(); perform pg_temp.svc();
  out := out || format(E'\n%s hub_plans: stored (%s), owner reads them via pl_plans', case when (r->>'plans')::int = 1 and w->'m12'->>'ref' = 'pvl' then 'PASS' else 'FAIL' end, r);
  perform pg_temp.anon_();
  begin w := public.pl_plans(); e := 'allowed'; exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s pl_plans: not for anon (%s)', case when e like 'permission denied%' then 'PASS' else 'FAIL' end, e);

  -- 11. add_business through the hub still works and gives no licence
  perform pg_temp.anon_();
  r := public.hub_call(tok, 'add_business', jsonb_build_object('business', 'PL009 Hub Shop', 'name', 'Kim Lee', 'email', 'pl009-hub@test.invalid', 'password', 'secret12'));
  perform pg_temp.svc();
  out := out || format(E'\n%s hub add_business: works, its location has no licence', case when r->>'account_id' is not null and not public.pl_site_open(r->>'org_id', r->>'site_id') then 'PASS' else 'FAIL' end);

  -- the migration text that ran (to compare with sha/md5 of the file in the repo)
  e := current_query(); mk := '-- 009: a licence per ' || 'LOCATION';
  out := out || format(E'\nINFO migration md5 as run: %s', case when position(mk in e) = 0 then 'n/a (run statement by statement)'
                       else md5(substring(e from position(mk in e)
                                          for position(E'\n-- TESTS\n' in e) + 1 - position(mk in e))) end);
  raise exception 'PL009 REPORT (rolled back):%', out || format(E'\n%s summary: %s PASS, %s FAIL', case when out like '%FAIL%' then 'FAIL' else 'PASS' end,
    (length(out) - length(replace(out, E'\nPASS', ''))) / 5, (length(out) - length(replace(out, E'\nFAIL', ''))) / 5);
end $T$;
