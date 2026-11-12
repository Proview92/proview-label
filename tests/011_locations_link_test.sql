-- Tests for supabase/migrations/011_locations_link.sql. Run as ONE query: the migration, then this file. It is all one
-- transaction that always fails at the end (the PASS/FAIL report is the error message), so nothing is kept:
--   { cat supabase/migrations/011_locations_link.sql; cat tests/011_locations_link_test.sql; }
do $T$
declare
  ok int := 0; bad text[] := '{}'; r jsonb; r2 jsonb; nid text; e text; n int;
  tok constant text := 'll-test-token';
  uo constant uuid := 'b1000000-0000-4000-8000-0000000000a1';  -- owner of A, admin of B
  ub constant uuid := 'b1000000-0000-4000-8000-0000000000a2';  -- owner of B
  um constant uuid := 'b1000000-0000-4000-8000-0000000000a3';  -- manager of A (site a1 only)
  un constant uuid := 'b1000000-0000-4000-8000-0000000000a4';  -- new self sign-up
  mu uuid;
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
  create or replace function pg_temp.chk(cond boolean, name text, inout ok int, inout bad text[]) language plpgsql as $f$
  begin if coalesce(cond, false) then ok := ok + 1; else bad := bad || name; end if; end $f$;

  update hub_private.config set token_sha256 = encode(extensions.digest(tok, 'sha256'), 'hex') where id = 1;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at) values
    ('00000000-0000-0000-0000-000000000000', uo, 'authenticated', 'authenticated', 'll-owner@test.invalid', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', ub, 'authenticated', 'authenticated', 'll-ownerb@test.invalid', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', um, 'authenticated', 'authenticated', 'll-mgr@test.invalid', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', un, 'authenticated', 'authenticated', 'll-new@test.invalid', now(), now(), now());
  -- fixtures made "earlier" (so they are not brand-new businesses of this transaction); the hub flag lets them in
  perform set_config('pl.hub_move', '1', true);
  insert into public.pl_orgs (id, name, settings, created_at) values
    ('org_ll_a', 'LL Alpha', '{"currency":"GBP"}', now() - interval '1 day'),
    ('org_ll_b', 'LL Beta', '{"currency":"EUR","logo":"b.png"}', now() - interval '1 day');
  insert into public.pl_records (id, org_id, site_id, kind, data) values
    ('ll_a1', 'org_ll_a', 'll_a1', 'sites', '{"id":"ll_a1","orgId":"org_ll_a","name":"Alpha One"}'),
    ('ll_a2', 'org_ll_a', 'll_a2', 'sites', '{"id":"ll_a2","orgId":"org_ll_a","name":"Alpha Two"}'),
    ('ll_b1', 'org_ll_b', 'll_b1', 'sites', '{"id":"ll_b1","orgId":"org_ll_b","name":"Beta One"}'),
    ('ll_ca', 'org_ll_a', null, 'categories', '{"id":"ll_ca","orgId":"org_ll_a","name":"Meat"}'),
    ('ll_ra', 'org_ll_a', null, 'rules', '{"id":"ll_ra","orgId":"org_ll_a","name":"Fridge"}'),
    ('ll_pa', 'org_ll_a', null, 'products', '{"id":"ll_pa","orgId":"org_ll_a","name":"Chicken","categoryId":"ll_ca","ruleId":"ll_ra"}'),
    ('ll_pb', 'org_ll_b', null, 'products', '{"id":"ll_pb","orgId":"org_ll_b","name":"Fish"}'),
    ('ll_la2', 'org_ll_a', 'll_a2', 'labels', '{"id":"ll_la2","orgId":"org_ll_a","siteId":"ll_a2","productId":"ll_pa"}'),
    ('ll_lb1', 'org_ll_b', 'll_b1', 'labels', '{"id":"ll_lb1","orgId":"org_ll_b","siteId":"ll_b1","productId":"ll_pb"}'),
    ('ll_u_only2', 'org_ll_a', null, 'users', '{"id":"ll_u_only2","orgId":"org_ll_a","name":"Only A2","siteIds":["ll_a2"]}'),
    ('ll_u_both', 'org_ll_a', null, 'users', '{"id":"ll_u_both","orgId":"org_ll_a","name":"Both","siteIds":["ll_a1","ll_a2"]}');
  insert into public.pl_members (org_id, email, user_id, name, role, site_ids) values
    ('org_ll_a', 'll-owner@test.invalid', uo, 'Owner A', 'owner', '{}'),
    ('org_ll_a', 'll-mgr@test.invalid', um, 'Mgr A', 'manager', '{ll_a1}'),
    ('org_ll_b', 'll-owner@test.invalid', uo, 'Owner A in B', 'admin', '{}'),
    ('org_ll_b', 'll-ownerb@test.invalid', ub, 'Owner B', 'owner', '{}');
  insert into public.pl_site_licences(site_id, org_id, licence_type) values ('ll_a1', 'org_ll_a', 'lifetime'), ('ll_b1', 'org_ll_b', 'lifetime');
  insert into public.pl_site_licences(site_id, org_id, licence_type, licence_expires_at) values ('ll_a2', 'org_ll_a', 'm12', now() + interval '200 days');
  perform set_config('pl.hub_move', '', true);

  -- 1) nobody adds or deletes a location in the app
  perform pg_temp.as_(uo);
  begin
    insert into public.pl_records(id, org_id, site_id, kind, data) values ('ll_new', 'org_ll_a', 'll_new', 'sites', '{"name":"New"}');
    bad := bad || 'owner adds a location';
  exception when others then select * into ok, bad from pg_temp.chk(sqlerrm like 'New locations are added by Proview%', 'owner add: message ' || sqlerrm, ok, bad); end;
  begin
    insert into public.pl_records(id, org_id, site_id, kind, data) values ('ll_a1', 'org_ll_a', 'll_a1', 'sites', '{"id":"ll_a1","orgId":"org_ll_a","name":"Alpha One renamed"}')
      on conflict (id) do update set data = excluded.data;
    select * into ok, bad from pg_temp.chk((select data->>'name' from public.pl_records where id = 'll_a1') = 'Alpha One renamed', 'owner edits a location (upsert)', ok, bad);
  exception when others then bad := bad || ('owner edits a location: ' || sqlerrm); end;
  begin
    update public.pl_records set deleted = true where id = 'll_a2';
    bad := bad || 'owner deletes a location';
  exception when others then select * into ok, bad from pg_temp.chk(sqlerrm like 'Locations can''t be deleted here%', 'owner delete: message', ok, bad); end;
  begin
    insert into public.pl_records(id, org_id, site_id, kind, data) values ('ll_a2', 'org_ll_a', 'll_a2', 'sites', '{"name":"x","deleted":true}')
      on conflict (id) do update set data = excluded.data, deleted = true;
    bad := bad || 'owner deletes a location by upsert';
  exception when others then ok := ok + 1; end;
  begin
    update public.pl_records set org_id = 'org_ll_b' where id = 'll_a2';
    if not found then ok := ok + 1; else bad := bad || 'owner moves a location to another business'; end if;
  exception when others then ok := ok + 1; end;
  -- the hub flag means nothing to a signed-in person
  perform set_config('pl.hub_move', '1', true);
  begin
    insert into public.pl_records(id, org_id, site_id, kind, data) values ('ll_new3', 'org_ll_a', 'll_new3', 'sites', '{"name":"New"}');
    bad := bad || 'owner adds a location with the hub flag set';
  exception when others then ok := ok + 1; end;
  perform set_config('pl.hub_move', '', true);
  perform pg_temp.svc();
  -- the master inside the business can't add one either
  select user_id into mu from public.pl_masters where user_id is not null limit 1;
  if mu is not null then
    perform pg_temp.as_(mu, 'org_ll_a');
    begin
      insert into public.pl_records(id, org_id, site_id, kind, data) values ('ll_new2', 'org_ll_a', 'll_new2', 'sites', '{"name":"New"}');
      bad := bad || 'master adds a location';
    exception when others then ok := ok + 1; end;
    perform pg_temp.svc();
  end if;
  -- other records still sync as before
  perform pg_temp.as_(uo);
  begin
    insert into public.pl_records(id, org_id, site_id, kind, data) values ('ll_p_new', 'org_ll_a', null, 'products', '{"name":"Lamb"}');
    ok := ok + 1;
  exception when others then bad := bad || ('owner adds a product: ' || sqlerrm); end;
  perform pg_temp.svc();
  -- the free self sign-up still makes one business with one location
  perform pg_temp.as_(un);
  begin
    r := public.pl_start_trial('LL Self', null);
    select * into ok, bad from pg_temp.chk(r ? 'site_id', 'self sign-up makes its first location', ok, bad);
  exception when others then bad := bad || ('self sign-up: ' || sqlerrm); end;
  perform pg_temp.svc();

  -- 2) hub: token, link, idempotent link, list
  begin perform public.hub_call('wrong', 'link', '{"into":"org_ll_a","from":"org_ll_b"}'); bad := bad || 'link with a wrong token';
  exception when others then ok := ok + 1; end;
  begin perform public.hub_call(tok, 'link', '{"into":"org_ll_a","from":"org_nope"}'); bad := bad || 'link with a missing account';
  exception when others then ok := ok + 1; end;
  perform pg_temp.as_(uo);
  begin perform hub_private.pl_link_orgs('org_ll_a', 'org_ll_b'); bad := bad || 'a person calls the link function';
  exception when others then ok := ok + 1; end;
  perform pg_temp.svc();

  execute 'set local role anon';
  r := public.hub_call(tok, 'link', '{"into":"org_ll_a","from":"org_ll_b"}');
  execute 'reset role';
  select * into ok, bad from pg_temp.chk(r->>'ok' = 'true' and r->>'account' = 'org_ll_a' and r->>'from' = 'org_ll_b' and r->'moved_sites' = '["ll_b1"]'
    and r->>'already' = 'false' and r->'renamed_units' = '[]', 'link result ' || r::text, ok, bad);
  select * into ok, bad from pg_temp.chk(not exists (select 1 from public.pl_orgs where id = 'org_ll_b'), 'B deleted', ok, bad);
  select * into ok, bad from pg_temp.chk(not exists (select 1 from public.pl_records where org_id = 'org_ll_b')
    and (select org_id from public.pl_records where id = 'll_b1') = 'org_ll_a'
    and (select data->>'orgId' from public.pl_records where id = 'll_lb1') = 'org_ll_a', 'B records moved (column and orgId)', ok, bad);
  select * into ok, bad from pg_temp.chk((select org_id from public.pl_site_licences where site_id = 'll_b1') = 'org_ll_a'
    and (select licence_type from public.pl_site_licences where site_id = 'll_b1') = 'lifetime', 'B licence moved unchanged', ok, bad);
  select * into ok, bad from pg_temp.chk((select role from public.pl_members where org_id = 'org_ll_a' and email = 'll-owner@test.invalid') = 'owner'
    and (select count(*) from public.pl_members where email = 'll-owner@test.invalid') = 1, 'person in both keeps the higher role', ok, bad);
  select * into ok, bad from pg_temp.chk((select role from public.pl_members where org_id = 'org_ll_a' and email = 'll-ownerb@test.invalid') = 'owner', 'B owner becomes owner of A', ok, bad);
  select * into ok, bad from pg_temp.chk((select site_ids from public.pl_members where org_id = 'org_ll_a' and email = 'll-mgr@test.invalid') = '{ll_a1,ll_a2,ll_b1}', 'A manager gets every location', ok, bad);
  select * into ok, bad from pg_temp.chk((select settings from public.pl_orgs where id = 'org_ll_a') = '{"currency":"GBP","logo":"b.png"}', 'settings: A wins, B fills in', ok, bad);
  -- B's owner now sees both locations, with the dropdown
  perform pg_temp.as_(ub);
  r2 := public.pl_whoami();
  perform pg_temp.svc();
  select * into ok, bad from pg_temp.chk(jsonb_array_length(r2->'orgs') = 1 and jsonb_array_length(r2->'orgs'->0->'sites') = 3, 'B owner sees the 3 linked locations', ok, bad);
  r2 := public.hub_call(tok, 'link', '{"into":"org_ll_a","from":"org_ll_b"}');
  select * into ok, bad from pg_temp.chk(r2->>'ok' = 'true' and r2->'moved_sites' = '["ll_b1"]' and r2->>'already' = 'true', 'link again: same answer, already', ok, bad);
  begin perform public.hub_call(tok, 'link', '{"into":"org_ll_x","from":"org_ll_b"}'); bad := bad || 'link B again into another account';
  exception when others then select * into ok, bad from pg_temp.chk(sqlerrm = 'org_ll_b was already linked into org_ll_a, not org_ll_x.', 'linked elsewhere: message ' || sqlerrm, ok, bad); end;
  begin perform public.hub_call(tok, 'link', '{"into":"org_ll_a","from":"org_ll_a"}'); bad := bad || 'link to itself';
  exception when others then select * into ok, bad from pg_temp.chk(sqlerrm = 'An account can''t be linked to itself.', 'itself: message', ok, bad); end;
  r2 := public.hub_call(tok, 'list', '{}');
  select * into ok, bad from pg_temp.chk((select count(*) from jsonb_array_elements(r2->'units') u where u->>'account_id' = 'org_ll_a') = 3
    and not exists (select 1 from jsonb_array_elements(r2->'accounts') x where x->>'id' = 'org_ll_b'), 'list shows the merged business', ok, bad);

  -- 3) unlink Alpha Two
  r := public.hub_call(tok, 'unlink', '{"account":"org_ll_a","site":"ll_a2"}');
  nid := r->>'account';
  select * into ok, bad from pg_temp.chk(r->>'ok' = 'true' and nid like 'org_%' and nid <> 'org_ll_a' and r->>'site' = 'll_a2' and r->>'from' = 'org_ll_a'
    and r->>'already' = 'false', 'unlink result ' || r::text, ok, bad);
  select * into ok, bad from pg_temp.chk((select name from public.pl_orgs where id = nid) = 'Alpha Two', 'new business named after the location', ok, bad);
  select * into ok, bad from pg_temp.chk((select org_id from public.pl_records where id = 'll_a2') = nid and (select org_id from public.pl_records where id = 'll_la2') = nid
    and (select data->>'orgId' from public.pl_records where id = 'll_la2') = nid, 'location and its labels moved', ok, bad);
  select * into ok, bad from pg_temp.chk((select org_id from public.pl_site_licences where site_id = 'll_a2') = nid
    and (select licence_type from public.pl_site_licences where site_id = 'll_a2') = 'm12', 'licence moved unchanged', ok, bad);
  select * into ok, bad from pg_temp.chk(exists (select 1 from public.pl_records where org_id = nid and kind = 'products' and data->>'name' = 'Chicken'
       and data->>'categoryId' like 'll_ca_%' and data->>'ruleId' like 'll_ra_%')
    and exists (select 1 from public.pl_records where id = 'll_pa' and org_id = 'org_ll_a'), 'menu copied, references re-pointed', ok, bad);
  select * into ok, bad from pg_temp.chk((select data->>'productId' from public.pl_records where id = 'll_la2') like 'll_pa_%'
    and exists (select 1 from public.pl_records where id = (select data->>'productId' from public.pl_records where id = 'll_la2') and org_id = nid), 'moved label points at the copied product', ok, bad);
  select * into ok, bad from pg_temp.chk((select org_id from public.pl_records where id = 'll_u_only2') = nid
    and (select data->'siteIds' from public.pl_records where id = 'll_u_both') = '["ll_a1"]'
    and exists (select 1 from public.pl_records where org_id = nid and kind = 'users' and data->>'name' = 'Both' and data->'siteIds' = '["ll_a2"]'), 'device staff moved / copied', ok, bad);
  select * into ok, bad from pg_temp.chk((select count(*) from public.pl_members where org_id = nid and role = 'owner') = 2, 'owners copied', ok, bad);
  r2 := public.hub_call(tok, 'unlink', '{"account":"org_ll_a","site":"ll_a2"}');
  select * into ok, bad from pg_temp.chk(r2->>'account' = nid and r2->>'already' = 'true', 'unlink again: same answer, already', ok, bad);
  begin perform public.hub_call(tok, 'unlink', jsonb_build_object('account', nid, 'site', 'll_a2')); bad := bad || 'unlink the only location';
  exception when others then select * into ok, bad from pg_temp.chk(sqlerrm like '%only that one location%', 'only location: message', ok, bad); end;
  begin perform public.hub_call(tok, 'unlink', '{"account":"org_ll_a","site":"ll_nope"}'); bad := bad || 'unlink a missing location';
  exception when others then select * into ok, bad from pg_temp.chk(sqlerrm = 'Location not found: ll_nope', 'missing location: message', ok, bad); end;
  select * into ok, bad from pg_temp.chk((select site_ids from public.pl_members where org_id = 'org_ll_a' and email = 'll-mgr@test.invalid') = '{ll_a1,ll_b1}'
    and (select site_ids from public.pl_members where org_id = nid and email = 'll-mgr@test.invalid') = '{ll_a2}', 'manager copied with that location only, A keeps them', ok, bad);
  -- the split owner sees Alpha Two on its own
  perform pg_temp.as_(ub);
  r2 := public.pl_whoami();
  perform pg_temp.svc();
  select * into ok, bad from pg_temp.chk(jsonb_array_length(r2->'orgs') = 2, 'owner now in two businesses after unlink', ok, bad);

  raise exception 'RESULT % passed, % failed: %', ok, coalesce(array_length(bad, 1), 0), array_to_string(bad, ' | ');
end $T$;
