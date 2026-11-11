-- Tests for supabase/migrations/007_no_trial.sql. Run as ONE query: the setup block, then the migration, then the
-- test block. It is all one transaction that always fails at the end (results in the error message): nothing is kept.
-- Build it with:
--   { sed -n '/^-- SETUP/,/^-- END SETUP/p' tests/007_no_trial_test.sql; cat supabase/migrations/007_no_trial.sql; sed -n '/^-- TESTS/,$p' tests/007_no_trial_test.sql; }

-- SETUP (runs on the functions as they are BEFORE 007): an existing self sign-up trial business
do $S$
declare u uuid := 'a0070000-0000-4000-8000-000000000001'; r jsonb;
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
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.headers', '{}', true);
  end $f$;
  create temp table t_before as
    select md5(coalesce(string_agg(o::text, '|' order by o.id), '')) orgs from public.pl_orgs o;
  insert into auth.users (id, email, aud, role, email_confirmed_at)
  values (u, 'pl007-oldtrial@test.invalid', 'authenticated', 'authenticated', now());
  perform pg_temp.as_(u);
  r := public.pl_start_trial('PL007 Old Trial', null);
  perform pg_temp.svc();
  create temp table t_old as select o.id, o.trial_ends_at from public.pl_orgs o where o.id = r->>'org_id';
end $S$;
-- END SETUP

-- (the migration goes here)

-- TESTS
do $T$
declare
  master uuid := (select user_id from public.pl_masters where email = 'altun@proviewtech.co.uk');
  u_self uuid := 'a0070000-0000-4000-8000-000000000002';
  u_used uuid := 'a0070000-0000-4000-8000-000000000003';
  u_dev  uuid := 'a0070000-0000-4000-8000-000000000004';
  u_old  uuid := 'a0070000-0000-4000-8000-000000000001';
  out text := ''; r jsonb; r2 jsonb; w jsonb; o jsonb; e text; n int; b boolean; oid text; ok boolean; old record;
begin
  if master is null then raise exception 'no master'; end if;
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (u_self, 'pl007-self@test.invalid', 'authenticated', 'authenticated', now()),
    (u_used, 'pl007-used@test.invalid', 'authenticated', 'authenticated', now()),
    (u_dev,  'pl007-dev@test.invalid',  'authenticated', 'authenticated', now());
  insert into public.pl_trials(email) values ('pl007-used@test.invalid');   -- had a trial before: no longer matters

  -- 1. master + Add business (pl_add_business; the licence portal's hub_call 'add_business' runs this same function)
  perform pg_temp.as_(master);
  r := public.pl_add_business('PL007 Added Cafe', 'Sam Taylor', 'pl007-added@test.invalid', '', 'secret12');
  perform pg_temp.svc();
  select (not licensed) and trial_ends_at is null into b from public.pl_orgs where id = r->>'org_id';
  out := out || format(E'\n%s Add business: no licence (licensed=false, no trial)', case when b then 'PASS' else 'FAIL' end);
  out := out || format(E'\n%s Add business: locked (pl_org_locked)', case when public.pl_org_locked(r->>'org_id') then 'PASS' else 'FAIL' end);
  perform pg_temp.as_((r->>'user_id')::uuid);
  w := public.pl_whoami();
  b := public.pl_can_write(r->>'org_id', r->>'site_id', 'products');
  ok := public.pl_can_read(r->>'org_id', r->>'site_id');
  perform pg_temp.svc();
  o := w->'orgs'->0;
  out := out || format(E'\n%s owner signs in: whoami lists it, owner, no_licence, locked (%s %s %s)',
    case when o->>'id' = r->>'org_id' and o->>'role' = 'owner' and (o->>'no_licence')::boolean and (o->>'locked')::boolean and not (o->>'trial_expired')::boolean then 'PASS' else 'FAIL' end, o->>'role', o->>'no_licence', o->>'locked');
  out := out || format(E'\n%s owner can read but not write (read %s, write %s)', case when ok and not b then 'PASS' else 'FAIL' end, ok, b);
  -- the owner can't give themselves a licence
  begin
    perform pg_temp.as_((r->>'user_id')::uuid);
    update public.pl_orgs set licensed = true where id = r->>'org_id';
    get diagnostics n = row_count;
    perform pg_temp.svc();
    e := 'rows ' || n;
  exception when others then perform pg_temp.svc(); e := sqlerrm; end;
  out := out || format(E'\n%s owner can''t set licensed (%s)', case when not (select licensed from public.pl_orgs where id = r->>'org_id') then 'PASS' else 'FAIL' end, left(e, 50));
  begin
    perform pg_temp.as_((r->>'user_id')::uuid);
    perform public.pl_set_licence(r->>'org_id', true, null);
    perform pg_temp.svc(); e := 'allowed';
  exception when others then perform pg_temp.svc(); e := sqlerrm; end;
  out := out || format(E'\n%s non-master pl_set_licence refused (%s)', case when e like 'Only a Proview master%' then 'PASS' else 'FAIL' end, e);
  -- a handheld paired to it (device login) is locked too
  insert into public.pl_devices(id, user_id, org_id, site_id, name) values ('dev_pl007', u_dev, r->>'org_id', r->>'site_id', 'Test handheld');
  perform pg_temp.as_(u_dev);
  w := public.pl_whoami();
  b := public.pl_can_write(r->>'org_id', r->>'site_id', 'labels');
  perform pg_temp.svc();
  o := w->'orgs'->0;
  out := out || format(E'\n%s handheld: whoami no_licence + locked, can''t write (%s %s %s)', case when (o->>'no_licence')::boolean and (o->>'locked')::boolean and not b then 'PASS' else 'FAIL' end, o->>'no_licence', o->>'locked', b);
  -- the master can still work inside it (x-pl-org)
  perform pg_temp.as_(master, r->>'org_id');
  b := public.pl_can_write(r->>'org_id', r->>'site_id', 'products');
  perform pg_temp.svc();
  out := out || format(E'\n%s master can still work inside the unlicensed business (%s)', case when b then 'PASS' else 'FAIL' end, b);
  -- master gives the licence -> open; removes it -> locked again
  perform pg_temp.as_(master);
  perform public.pl_set_licence(r->>'org_id', true, null);
  perform pg_temp.svc();
  perform pg_temp.as_((r->>'user_id')::uuid);
  b := public.pl_can_write(r->>'org_id', r->>'site_id', 'products'); o := public.pl_whoami()->'orgs'->0;
  perform pg_temp.svc();
  out := out || format(E'\n%s master gives the licence: owner can write, not locked (%s %s)', case when b and not (o->>'locked')::boolean then 'PASS' else 'FAIL' end, b, o->>'locked');
  perform pg_temp.as_(master);
  perform public.pl_set_licence(r->>'org_id', false, null);
  perform pg_temp.svc();
  out := out || format(E'\n%s master removes the licence: locked again', case when public.pl_org_locked(r->>'org_id') then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(master);
  perform public.pl_set_trial(r->>'org_id', now() + interval '7 days');
  perform pg_temp.svc();
  select licensed and trial_ends_at > now() + interval '6 days' into b from public.pl_orgs where id = r->>'org_id';
  out := out || format(E'\n%s master sets a trial by hand (pl_set_trial): licensed with that end date', case when b and not public.pl_org_locked(r->>'org_id') then 'PASS' else 'FAIL' end);

  -- 2. older master function pl_create_org
  perform pg_temp.as_(master);
  oid := public.pl_create_org('PL007 Old Create', 'pl007-co@test.invalid', 'Co');
  perform pg_temp.svc();
  out := out || format(E'\n%s pl_create_org: no licence', case when not (select licensed from public.pl_orgs where id = oid) and public.pl_org_locked(oid) then 'PASS' else 'FAIL' end);
  -- a plain insert (any other path) also starts with no licence
  insert into public.pl_orgs(name) values ('PL007 Plain Insert') returning id into oid;
  out := out || format(E'\n%s any new pl_orgs row: no licence by default', case when not (select licensed from public.pl_orgs where id = oid) then 'PASS' else 'FAIL' end);

  -- 3. self sign-up ("Set up your business")
  perform pg_temp.as_(u_self);
  r2 := public.pl_start_trial('PL007 Self Biz', 'PL007 Kitchen');
  w := public.pl_whoami();
  perform pg_temp.svc();
  select (not licensed) and trial_ends_at is null into b from public.pl_orgs where id = r2->>'org_id';
  out := out || format(E'\n%s self sign-up: no licence, no trial (%s)', case when b and (r2->>'trial_ends_at') is null then 'PASS' else 'FAIL' end, r2);
  o := w->'orgs'->0;
  out := out || format(E'\n%s self sign-up: Owner, no_licence, locked; trial_used false', case when o->>'role' = 'owner' and (o->>'no_licence')::boolean and (o->>'locked')::boolean and not (w->>'trial_used')::boolean then 'PASS' else 'FAIL' end);
  select count(*) into n from public.pl_records where org_id = r2->>'org_id' and kind = 'sites' and data->>'name' = 'PL007 Kitchen';
  out := out || format(E'\n%s self sign-up: first location made (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.pl_trials where email = 'pl007-self@test.invalid';
  out := out || format(E'\n%s self sign-up: no one-trial-per-email record written (%s)', case when n = 0 then 'PASS' else 'FAIL' end, n);
  perform pg_temp.as_(u_used);
  w := public.pl_whoami();
  r2 := public.pl_start_trial('PL007 Used Biz', null);
  perform pg_temp.svc();
  out := out || format(E'\n%s email already in pl_trials: whoami trial_used=false, set-up allowed, no licence', case when not (w->>'trial_used')::boolean and not (select licensed from public.pl_orgs where id = r2->>'org_id') then 'PASS' else 'FAIL' end);
  begin
    perform pg_temp.as_(u_used); perform public.pl_start_trial('PL007 Again', null); perform pg_temp.svc(); e := 'allowed';
  exception when others then perform pg_temp.svc(); e := sqlerrm; end;
  out := out || format(E'\n%s someone with a business can''t set up another (%s)', case when e like 'ALREADY_MEMBER%' then 'PASS' else 'FAIL' end, left(e, 40));
  insert into public.pl_trials(email) values ('pl007-nobiz-used@test.invalid');
  out := out || format(E'\n%s Proview account sign-in no longer refused for an email that had a trial (%s)',
    case when (public.sso_entitled('pl007-nobiz-used@test.invalid')->>'ok')::boolean then 'PASS' else 'FAIL' end, public.sso_entitled('pl007-nobiz-used@test.invalid'));

  -- 4. a location added later: in a licensed business it stays licensed (the licence is the business's); in an
  --    unlicensed one it can't even be added by its owner
  perform pg_temp.as_(u_self);
  begin
    insert into public.pl_records(id, org_id, site_id, kind, data) values ('site_pl007b', (w->'orgs'->0->>'id'), 'site_pl007b', 'sites', '{"name":"Second"}');
    e := 'allowed';
  exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s unlicensed owner can''t add a location (%s)', case when e <> 'allowed' then 'PASS' else 'FAIL' end, left(e, 50));

  -- 5. existing trial business unchanged
  select * into old from t_old;
  select licensed and trial_ends_at = old.trial_ends_at into b from public.pl_orgs where id = old.id;
  out := out || format(E'\n%s existing trial business: still licensed, trial_ends_at unchanged (%s)', case when b and old.trial_ends_at > now() + interval '71 hours' then 'PASS' else 'FAIL' end, old.trial_ends_at);
  perform pg_temp.as_(u_old);
  o := public.pl_whoami()->'orgs'->0;
  b := public.pl_can_write(old.id, null, 'products');
  perform pg_temp.svc();
  out := out || format(E'\n%s existing trial business: owner not locked, can write (%s %s)', case when not (o->>'locked')::boolean and not (o->>'no_licence')::boolean and b then 'PASS' else 'FAIL' end, o->>'locked', b);

  -- 6. non-master refused
  perform pg_temp.as_(u_self);
  begin perform public.pl_add_business('PL007 Nope', 'No One', 'pl007-nope@test.invalid', '', 'secret12'); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s non-master pl_add_business refused (%s)', case when e like 'Only a Proview master%' then 'PASS' else 'FAIL' end, e);
  begin perform public.pl_create_org('PL007 Nope', null, ''); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s non-master pl_create_org refused (%s)', case when e like 'Only a Proview master%' then 'PASS' else 'FAIL' end, e);
  begin perform public.pl_set_trial(old.id, null); e := 'allowed'; exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s non-master pl_set_trial refused (%s)', case when e like 'Only a Proview master%' then 'PASS' else 'FAIL' end, e);
  perform pg_temp.svc();

  -- 7. real businesses untouched (test rows excluded; the new column is not part of the fingerprint)
  select t.orgs = (select md5(coalesce(string_agg((o2.id, o2.name, o2.settings, o2.suspended, o2.created_at, o2.trial_ends_at, o2.trial_email)::text, '|' order by o2.id), ''))
                     from public.pl_orgs o2 where o2.name not like 'PL007 %') into ok from t_before t;
  select ok and not exists (select 1 from public.pl_orgs where name not like 'PL007 %' and not licensed) into ok;
  out := out || format(E'\n%s real businesses unchanged and still licensed', case when ok then 'PASS' else 'FAIL' end);

  raise exception 'ROLLBACK (test only)%', out;
end $T$;
