-- Test for 017_standard_roles.sql. Paste into the SQL editor of proview-label (fiqoirnlmhjzicvktdwa) AFTER the migration.
-- Throw-away rows (zz017 / example.invalid); it ALWAYS ends with an exception listing PASS / FAIL, which rolls back.
do $t$
declare out text[] := '{}'; tok text := 'zz017-hub-token'; oa text; ua uuid := gen_random_uuid(); um uuid := gen_random_uuid();
        us uuid := gen_random_uuid(); j jsonb; r jsonb; n int; ok boolean;
begin
  update hub_private.config set token_sha256 = encode(extensions.digest(tok, 'sha256'), 'hex') where id = 1;
  insert into pl_orgs(name) values ('zz017 Alpha') returning id into oa;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, is_anonymous) values
    (ua, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz017-adm@example.invalid', '', now(), now(), now(), false),
    (um, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz017-mgr@example.invalid', '', now(), now(), now(), false),
    (us, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz017-stf@example.invalid', '', now(), now(), now(), false);

  begin insert into pl_members(org_id, email, role) values (oa, 'zz017-o@example.invalid', 'owner'); out := out || 'FAIL owner role accepted'::text;
  exception when check_violation then out := out || 'PASS owner role refused by the table'::text; end;
  insert into pl_members(org_id, email, user_id, role) values (oa, 'zz017-adm@example.invalid', ua, 'admin');
  insert into pl_members(org_id, email, user_id, role, features) values (oa, 'zz017-mgr@example.invalid', um, 'manager', '{}');
  insert into pl_members(org_id, email, user_id, role, features) values (oa, 'zz017-stf@example.invalid', us, 'staff', '{"wastage": false}');
  out := out || 'PASS a staff login can be stored'::text;
  select count(*) into n from pl_members where lower(role) = 'owner';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' no owner left in pl_members (' || n || ')');
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname in ('public', 'hub_private') and p.prosrc ~ '''owner''|"owner"';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' no function uses the owner role (' || n || ')');
  select count(*) into n from pg_policies where coalesce(qual, '') || coalesce(with_check, '') ~* 'owner';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' no policy uses the owner role (' || n || ')');

  -- as the admin: add another admin and a staff login (RLS)
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'email', 'zz017-adm@example.invalid', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', ua::text, true);
  execute 'set local role authenticated';
  begin insert into pl_members(org_id, email, role) values (oa, 'zz017-adm2@example.invalid', 'admin'); out := out || 'PASS an admin adds another admin'::text;
  exception when others then out := out || ('FAIL admin adds admin: ' || sqlerrm); end;
  begin insert into pl_members(org_id, email, role, site_ids) values (oa, 'zz017-stf2@example.invalid', 'staff', '{}'); out := out || 'PASS an admin adds a staff login'::text;
  exception when others then out := out || ('FAIL admin adds staff: ' || sqlerrm); end;
  ok := public.pl_is_org_admin(oa);
  out := out || ((case when ok then 'PASS' else 'FAIL' end) || ' an admin has the old owner rights');
  execute 'reset role';
  -- as the manager: can't add users
  perform set_config('request.jwt.claims', json_build_object('sub', um, 'email', 'zz017-mgr@example.invalid', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', um::text, true);
  execute 'set local role authenticated';
  begin insert into pl_members(org_id, email, role) values (oa, 'zz017-y@example.invalid', 'staff'); out := out || 'FAIL a manager added a user'::text;
  exception when others then out := out || 'PASS a manager can''t manage users'::text; end;
  execute 'reset role';
  -- as the staff login: scoped, and its switched-off feature is off
  perform set_config('request.jwt.claims', json_build_object('sub', us, 'email', 'zz017-stf@example.invalid', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', us::text, true);
  execute 'set local role authenticated';
  ok := public.pl_has_feature(oa, 'wastage');
  out := out || ((case when not ok then 'PASS' else 'FAIL' end) || ' staff: a feature switched off is off');
  ok := public.pl_is_org_admin(oa);
  out := out || ((case when not ok then 'PASS' else 'FAIL' end) || ' staff is not an admin');
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('request.jwt.claim.sub', '', true);

  -- the licence portal: role list Admin / Manager / Staff; New business makes an Admin
  j := hub_users(tok, 'list', jsonb_build_object('account', oa));
  out := out || ((case when (j->'roles')::text !~* 'owner' and (j->'roles')::text ~ '"staff"' and (j->'roles')::text ~ '"admin"' then 'PASS' else 'FAIL' end) || ' portal role list: ' || coalesce((j->'roles')::text, j::text));
  begin
    j := hub_call(tok, 'add_business', jsonb_build_object('business', 'zz017 Beta', 'name', 'Bea Test', 'email', 'zz017-bea@example.invalid', 'password', 'longpassword17'));
    select to_jsonb(m.role) into r from pl_members m where m.email = 'zz017-bea@example.invalid';
    out := out || ((case when r #>> '{}' = 'admin' then 'PASS' else 'FAIL' end) || ' New business makes its login an Admin (' || coalesce(r #>> '{}', 'none') || ')');
  exception when others then out := out || ('FAIL add_business: ' || sqlerrm); end;

  -- sign-in check
  r := public.sso_entitled('zz017-stranger@example.invalid');
  out := out || ((case when r->>'reason' = 'No Proview Label account for this email.' then 'PASS' else 'FAIL' end) || ' stranger: ' || coalesce(r->>'reason', r::text));
  r := public.sso_entitled('zz017-stf2@example.invalid');
  out := out || ((case when (r->>'ok')::boolean and (r->>'create')::boolean then 'PASS' else 'FAIL' end) || ' staff with no login yet: let in, login made');
  update pl_orgs set suspended = true where id = oa;
  r := public.sso_entitled('zz017-mgr@example.invalid');
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' member of a paused business: let in (sees the pause inside)');
  r := public.sso_entitled((select email from pl_masters limit 1));
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' the master is let in');

  raise exception E'017 LABEL TEST RESULT (rolled back): %/% PASS\n%',
    (select count(*) from unnest(out) x where x like 'PASS%'), array_length(out, 1), array_to_string(out, E'\n');
end $t$;
