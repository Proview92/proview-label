-- Tests for supabase/migrations/010_master_open.sql. Run as ONE query: the setup block, then the migration, then the test
-- block. It is all one transaction that always fails at the end (the PASS/FAIL report is the error message), so nothing
-- is kept. Build it with:
--   { sed -n '/^-- SETUP/,/^-- END SETUP/p' tests/010_master_open_test.sql; cat supabase/migrations/010_master_open.sql; sed -n '/^-- TESTS/,$p' tests/010_master_open_test.sql; }

-- SETUP (on the functions as they are BEFORE 010): test businesses and logins, then what everyone but the master sees
do $S$
declare mu uuid;
begin
  create or replace function pg_temp.as_(uid uuid, org text default null) returns void language plpgsql as $f$
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', uid::text, true);
    perform set_config('request.headers', case when org is null then '{}' else json_build_object('x-pl-org', org)::text end, true);
    execute 'set local role authenticated';
  end $f$;
  create or replace function pg_temp.svc() returns void language plpgsql as $f$
  begin
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true); perform set_config('request.headers', '{}', true);
  end $f$;
  -- what one login sees (whoami + every row id it can read), as that login, optionally with an x-pl-org header
  create or replace function pg_temp.sees(uid uuid, org text default null) returns jsonb language plpgsql as $f$
  declare out jsonb;
  begin
    perform pg_temp.as_(uid, org);
    select jsonb_build_object(
      'who', public.pl_whoami(),
      'records', (select coalesce(jsonb_agg(id order by id), '[]') from public.pl_records),
      'orgs', (select coalesce(jsonb_agg(id order by id), '[]') from public.pl_orgs),
      'devices', (select coalesce(jsonb_agg(id order by id), '[]') from public.pl_devices),
      'members', (select coalesce(jsonb_agg(id order by id), '[]') from public.pl_members)) into out;
    perform pg_temp.svc();
    return out;
  end $f$;
  -- fixtures: two businesses, an owner and a manager of the first, a handheld in the second
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at) values
    ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-4000-8000-0000000000a1', 'authenticated', 'authenticated', 'mo-owner@test.invalid', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-4000-8000-0000000000a2', 'authenticated', 'authenticated', 'mo-mgr@test.invalid', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-4000-8000-0000000000a3', 'authenticated', 'authenticated', 'mo-dev@test.invalid', now(), now(), now());
  insert into public.pl_orgs (id, name) values ('org_mo_t1', 'MO Test One'), ('org_mo_t2', 'MO Test Two');
  insert into public.pl_records (id, org_id, site_id, kind, data) values
    ('mo_s1a', 'org_mo_t1', 'mo_s1a', 'sites', '{"name":"T1 A"}'), ('mo_s1b', 'org_mo_t1', 'mo_s1b', 'sites', '{"name":"T1 B"}'),
    ('mo_s2', 'org_mo_t2', 'mo_s2', 'sites', '{"name":"T2"}'),
    ('mo_p1', 'org_mo_t1', null, 'products', '{"name":"P1"}'), ('mo_p2', 'org_mo_t2', null, 'products', '{"name":"P2"}'),
    ('mo_d1', 'org_mo_t1', 'mo_s1a', 'devices', '{"name":"D1"}'), ('mo_d2', 'org_mo_t2', 'mo_s2', 'devices', '{"name":"D2"}');
  insert into public.pl_members (org_id, email, user_id, name, role, site_ids) values
    ('org_mo_t1', 'mo-owner@test.invalid', 'a0000000-0000-4000-8000-0000000000a1', 'Owner', 'owner', '{}'),
    ('org_mo_t1', 'mo-mgr@test.invalid', 'a0000000-0000-4000-8000-0000000000a2', 'Mgr', 'manager', '{mo_s1a}');
  insert into public.pl_devices (id, user_id, org_id, site_id, name) values ('dev_mo_2', 'a0000000-0000-4000-8000-0000000000a3', 'org_mo_t2', 'mo_s2', 'HH');
  -- everyone but the master (fixtures and every real login and handheld), without and with a header
  create temp table t_before(uid uuid, hdr text, seen jsonb);
  insert into t_before(uid, hdr)
    select u, h from (select user_id u from public.pl_members where user_id is not null union select user_id from public.pl_devices where user_id is not null) x
      cross join (values (null::text), ('org_mo_t1'), ('org_mo_t2')) h(h)
     where not exists (select 1 from public.pl_masters where user_id = x.u);
  update t_before set seen = pg_temp.sees(uid, hdr);
  -- the master before 010 (for the report): every business with no header
  select user_id into mu from public.pl_masters where user_id is not null limit 1;
  create temp table t_master(k text, v jsonb);
  insert into t_master values ('uid', to_jsonb(mu)), ('before', pg_temp.sees(mu, null));
end $S$;
-- END SETUP

-- TESTS (after 010)
do $T$
declare rep text := ''; n int; mu uuid := (select (v#>>'{}')::uuid from t_master where k = 'uid');
  b jsonb := (select v from t_master where k = 'before'); none jsonb; t1 jsonb; t2 jsonb; bogus jsonb; bad int;
  procedure_ok boolean;
begin
  -- 1. everyone but the master: exactly as before (whoami, records, orgs, devices, members; with or without a header)
  select count(*) into bad from t_before t where pg_temp.sees(t.uid, t.hdr) is distinct from t.seen;
  select count(*) into n from t_before;
  rep := rep || case when bad = 0 and n > 0 then 'PASS' else 'FAIL' end || format(' non-master logins and handhelds unchanged (%s checks, %s differ)', n, bad) || E'\n';
  rep := rep || case when (select count(*) from t_before where uid = 'a0000000-0000-4000-8000-0000000000a3' and seen->'who'->'device' is not null) = 3 then 'PASS' else 'FAIL' end || ' handheld still gets its device whoami' || E'\n';
  rep := rep || case when (select seen->'records' from t_before where uid = 'a0000000-0000-4000-8000-0000000000a2' and hdr is null) = '["mo_d1","mo_p1","mo_s1a"]'::jsonb then 'PASS' else 'FAIL' end || ' manager still reads its own location only' || E'\n';
  if mu is null then rep := rep || E'FAIL no master login to test\n'; raise exception E'\n%', rep; end if;
  -- 2. the master
  none := pg_temp.sees(mu, null); t1 := pg_temp.sees(mu, 'org_mo_t1'); t2 := pg_temp.sees(mu, 'org_mo_t2'); bogus := pg_temp.sees(mu, 'org_does_not_exist');
  rep := rep || case when jsonb_array_length(b->'who'->'orgs') >= 2 and (b->'records') @> '["mo_s2","mo_d2"]' then 'PASS' else 'FAIL' end || format(' (before 010: master saw %s businesses without a header, and every business''s sites/devices)', jsonb_array_length(b->'who'->'orgs')) || E'\n';
  rep := rep || case when (none->'who'->>'master')::boolean and none->'who'->'orgs' = '[]' then 'PASS' else 'FAIL' end || ' master, no header: whoami says master, no business' || E'\n';
  rep := rep || case when none->'records' = '[]' and none->'orgs' = '[]' and none->'devices' = '[]' and none->'members' = '[]' then 'PASS' else 'FAIL' end || ' master, no header: no records, businesses, devices or members' || E'\n';
  rep := rep || case when jsonb_array_length(t1->'who'->'orgs') = 1 and t1->'who'->'orgs'->0->>'id' = 'org_mo_t1' and t1->'who'->'orgs'->0->>'role' = 'master'
                       and jsonb_array_length(t1->'who'->'orgs'->0->'sites') = 2 then 'PASS' else 'FAIL' end || ' master + x-pl-org T1: whoami has T1 only, with its 2 locations' || E'\n';
  rep := rep || case when t1->'records' = '["mo_d1","mo_p1","mo_s1a","mo_s1b"]'::jsonb and t1->'orgs' = '["org_mo_t1"]'::jsonb then 'PASS' else 'FAIL' end || ' master + T1: records and business of T1 only (no T2 sites/devices)' || E'\n';
  rep := rep || case when t1->'devices' = '[]' and (select count(*) from jsonb_array_elements_text(t1->'members') x where x not in (select id from public.pl_members where org_id = 'org_mo_t1')) = 0
                       and jsonb_array_length(t1->'members') = 2 then 'PASS' else 'FAIL' end || ' master + T1: members of T1 only; T2''s handheld not visible' || E'\n';
  rep := rep || case when t2->'records' = '["mo_d2","mo_p2","mo_s2"]'::jsonb and t2->'devices' = '["dev_mo_2"]'::jsonb and t2->'who'->'orgs'->0->>'id' = 'org_mo_t2'
                       and jsonb_array_length(t2->'who'->'orgs') = 1 then 'PASS' else 'FAIL' end || ' master + T2: T2 only (records, handheld, whoami)' || E'\n';
  rep := rep || case when bogus->'who'->'orgs' = '[]' and bogus->'records' = '[]' then 'PASS' else 'FAIL' end || ' master + unknown business: nothing' || E'\n';
  -- 2b. no business open: the master's admin / write checks are false, not null (an "if not ..." RPC check must refuse)
  perform pg_temp.as_(mu, null);
  rep := rep || case when public.pl_is_org_admin('org_mo_t1') is false and public.pl_can_write('org_mo_t1', 'mo_s1a', 'labels') is false
                       and public.pl_master_in('org_mo_t1') is false then 'PASS' else 'FAIL' end || ' master, no header: admin / write checks are false (not null)' || E'\n';
  perform pg_temp.svc();
  -- 3. writes as before: the master inside T1 can write T1, not T2
  perform pg_temp.as_(mu, 'org_mo_t1');
  rep := rep || case when public.pl_can_write('org_mo_t1', 'mo_s1a', 'labels') and not public.pl_can_write('org_mo_t2', 'mo_s2', 'labels') then 'PASS' else 'FAIL' end || ' master writes only in the open business (unchanged)' || E'\n';
  perform pg_temp.svc();
  -- 4. the licence portal's functions don't use what changed, and run as the owner (RLS not forced)
  rep := rep || case when not exists (select 1 from pg_proc where proname in ('hub_call', 'hub_call_base', 'hub_plans', 'pl_apply_site_licence', 'pl_site_lic_json')
                         and prosrc ~* '(pl_can_read_kind|pl_whoami|"orgs read")')
                       and not (select relforcerowsecurity from pg_class where oid = 'public.pl_records'::regclass)
                       and not (select relforcerowsecurity from pg_class where oid = 'public.pl_orgs'::regclass)
                       and (select prosecdef from pg_proc where proname = 'hub_call' and pronamespace = 'public'::regnamespace) then 'PASS' else 'FAIL' end
         || ' licence portal (hub_call, SECURITY DEFINER, RLS not forced) unaffected' || E'\n';
  -- 4b. the portal's hub_call 'list' (called with the anon key) still lists every business and location
  insert into hub_private.config (id, token_sha256) values (1, encode(extensions.digest('mo-test-token', 'sha256'), 'hex'))
    on conflict (id) do update set token_sha256 = excluded.token_sha256;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon';
  t1 := public.hub_call('mo-test-token', 'list', '{}');
  perform pg_temp.svc();
  rep := rep || case when (select count(*) from jsonb_array_elements(t1->'accounts') a where a->>'id' in ('org_mo_t1', 'org_mo_t2')) = 2
                       and (select count(*) from jsonb_array_elements(t1->'units') u where u->>'id' in ('mo_s1a', 'mo_s1b', 'mo_s2')) = 3 then 'PASS' else 'FAIL' end
         || ' hub_call list (licence portal) still sees every business and location' || E'\n';
  -- 5. grants kept
  rep := rep || case when has_function_privilege('authenticated', 'public.pl_whoami()', 'execute') and not has_function_privilege('anon', 'public.pl_whoami()', 'execute')
                       and has_function_privilege('authenticated', 'public.pl_can_read_kind(text,text,text)', 'execute') then 'PASS' else 'FAIL' end || ' grants unchanged' || E'\n';
  raise exception E'\n%(rolled back: nothing kept)', rep;
end $T$;
