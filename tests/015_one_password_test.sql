-- Test for 015_one_password.sql (one password on every Proview site). Paste the whole file into the SQL editor of Proview Label
-- (fiqoirnlmhjzicvktdwa) AFTER the migration and press Run. It is one DO block: it adds throw-away logins (emails under
-- example.invalid), a throw-away hub token and a business, checks the trigger, hub_call 'password_changes' /
-- 'set_password_hash' and sso_entitled, then ALWAYS ends with an exception whose text lists every PASS / FAIL.
-- The exception rolls everything back, so nothing it added or changed stays (the real hub token included).
do $test$
declare
  out text[] := '{}';
  t   text := 'zz-pwtest-' || substr(md5(random()::text), 1, 8);   -- unique per run, never a real email
  tok text := 'pwtest-token-' || md5(random()::text);
  own uuid := gen_random_uuid(); stf uuid := gen_random_uuid(); held uuid := gen_random_uuid();
  unc uuid := gen_random_uuid(); anon_u uuid := gen_random_uuid();
  h1 text := extensions.crypt('first-password', extensions.gen_salt('bf', 4));
  h2 text := extensions.crypt('second-password', extensions.gen_salt('bf', 4));
  h3 text := extensions.crypt('third-password', extensions.gen_salt('bf', 4));
  r jsonb; n int; n2 int; ok boolean; msg text; c0 timestamptz; conf timestamptz; ban timestamptz; biz text;
begin
  -- ---------- setup (as postgres) ----------
  insert into hub_private.config (id, token_sha256) values (1, encode(extensions.digest(tok, 'sha256'), 'hex'))
    on conflict (id) do update set token_sha256 = excluded.token_sha256;
  c0 := clock_timestamp();
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, recovery_token, banned_until, created_at, updated_at, is_anonymous)
  values
    (own,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', t || '-owner@example.invalid', h1, now(), '', null, now(), now(), false),
    (stf,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', t || '-staff@example.invalid', h1, now(), 'pending-reset', null, now(), now(), false),
    (held,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', t || '-held@example.invalid',  h1, now(), '', now() + interval '100 years', now(), now(), false),
    (unc,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', t || '-unconfirmed@example.invalid', h1, null, '', null, now(), now(), false),
    (anon_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', null, '', null, '', null, now(), now(), true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, is_anonymous)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dev_' || replace(t, '-', '') || '@devices.label.proviewcrm.co.uk', h1, now(), now(), now(), false);
  -- ---------- trigger ----------
  select count(*) into n from hub_private.pw_changes where email like t || '%' and kind = 'new' and source = 'user';
  out := out || ((case when n = 4 then 'PASS' else 'FAIL' end) || ' a new login is recorded as kind new (' || n || ' of 4; anonymous not recorded)');
  select (hash = h1) into ok from hub_private.pw_changes where email = t || '-owner@example.invalid' and kind = 'new';
  out := out || ((case when ok then 'PASS' else 'FAIL' end) || ' the new login''s bcrypt hash is kept');
  update auth.users set encrypted_password = h2 where id = own;
  select count(*) into n from hub_private.pw_changes where email = t || '-owner@example.invalid' and kind = 'set' and source = 'user' and hash = h2;
  out := out || ((case when n = 1 then 'PASS' else 'FAIL' end) || ' a changed password is recorded as kind set, source user');
  update auth.users set encrypted_password = h2, last_sign_in_at = now() where id = own;
  update auth.users set raw_user_meta_data = '{"x":1}' where id = own;
  update auth.users set encrypted_password = '' where id = own;
  select count(*) into n from hub_private.pw_changes where email = t || '-owner@example.invalid' and kind = 'set';
  out := out || ((case when n = 1 then 'PASS' else 'FAIL' end) || ' same hash, other columns and an empty password are not recorded (' || n || ')');
  update auth.users set encrypted_password = h3, raw_app_meta_data = '{"must_change_password": true}'::jsonb where id = own;   -- an admin's temporary password
  update auth.users set encrypted_password = h1, raw_app_meta_data = '{"temp_password_expired": true}'::jsonb where id = own;  -- ... replaced when it expires
  select count(*) into n from hub_private.pw_changes where email = t || '-owner@example.invalid' and kind = 'set';
  out := out || ((case when n = 1 then 'PASS' else 'FAIL' end) || ' a temporary password (must change at next sign-in) is never recorded (' || n || ')');
  update auth.users set raw_app_meta_data = '{}'::jsonb where id = own;

  -- ---------- hub_call: the token ----------
  begin perform public.hub_call('wrong-token', 'password_changes', '{}'::jsonb); msg := 'no error';
  exception when others then msg := sqlerrm; end;
  out := out || ((case when msg = 'not authorised' then 'PASS' else 'FAIL' end) || ' password_changes with a wrong token: ' || msg);
  begin perform public.hub_call(null, 'set_password_hash', jsonb_build_object('email', t || '-staff@example.invalid', 'hash', h3, 'changed_at', now())); msg := 'no error';
  exception when others then msg := sqlerrm; end;
  out := out || ((case when msg = 'not authorised' then 'PASS' else 'FAIL' end) || ' set_password_hash without a token: ' || msg);
  select encrypted_password = h1 into ok from auth.users where id = stf;
  out := out || ((case when ok then 'PASS' else 'FAIL' end) || ' ... and nothing changed');

  -- ---------- password_changes ----------
  r := public.hub_call(tok, 'password_changes', jsonb_build_object('since', c0 - interval '1 second'));
  select count(*) into n from jsonb_array_elements(r->'changes') x where x->>'email' like t || '%';
  out := out || ((case when n = 4 then 'PASS' else 'FAIL' end) || ' password_changes since: 4 changes of confirmed logins (' || n || ')');
  select count(*) into n from jsonb_array_elements(r->'changes') x where x->>'email' = t || '-unconfirmed@example.invalid';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' an unconfirmed login is not sent');
  select count(*) into n from jsonb_array_elements(r->'changes') x where x->>'email' = t || '-owner@example.invalid' and x->>'hash' = h2 and x->>'kind' = 'set' and x ? 'changed_at';
  out := out || ((case when n = 1 then 'PASS' else 'FAIL' end) || ' a change carries email, hash, changed_at and kind');
  r := public.hub_call(tok, 'password_changes', jsonb_build_object('since', now() + interval '1 minute'));
  out := out || ((case when jsonb_array_length(r->'changes') = 0 and r->>'more' = 'false' then 'PASS' else 'FAIL' end) || ' nothing after a later since');
  r := public.hub_call(tok, 'password_changes', jsonb_build_object('since', c0 - interval '1 second', 'limit', 1));
  out := out || ((case when jsonb_array_length(r->'changes') = 1 and r->>'more' = 'true' then 'PASS' else 'FAIL' end) || ' limit 1 -> one change and more = true');

  -- ---------- set_password_hash ----------
  select count(*) into n from auth.users;
  r := public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', t || '-nobody@example.invalid', 'hash', h3, 'changed_at', now()));
  select count(*) into n2 from auth.users;
  out := out || ((case when r->>'applied' = 'false' and r->>'reason' = 'no login' and n = n2 then 'PASS' else 'FAIL' end) || ' no login here -> nothing applied and no login made ' || r::text);

  select email_confirmed_at into conf from auth.users where id = stf;
  r := public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', upper(t) || '-STAFF@example.invalid', 'hash', h3, 'changed_at', clock_timestamp()));
  out := out || ((case when r->>'applied' = 'true' then 'PASS' else 'FAIL' end) || ' newer change -> applied ' || r::text);
  select encrypted_password = h3 and email_confirmed_at is not distinct from conf and coalesce(recovery_token, '') = '' into ok from auth.users where id = stf;
  out := out || ((case when ok then 'PASS' else 'FAIL' end) || ' hash set, email_confirmed_at kept, recovery token cleared');
  select extensions.crypt('third-password', encrypted_password) = encrypted_password into ok from auth.users where id = stf;
  out := out || ((case when ok then 'PASS' else 'FAIL' end) || ' the password that made the hash now signs in here');
  select count(*) into n from hub_private.pw_changes where email = t || '-staff@example.invalid' and source = 'sync' and hash = h3;
  out := out || ((case when n = 1 then 'PASS' else 'FAIL' end) || ' recorded once, as source sync');
  select count(*) into n from hub_private.pw_changes where email = t || '-staff@example.invalid' and source = 'user' and kind = 'set';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' the trigger did not record it as a change made here');
  r := public.hub_call(tok, 'password_changes', jsonb_build_object('since', c0 - interval '1 second'));
  select count(*) into n from jsonb_array_elements(r->'changes') x where x->>'email' = t || '-staff@example.invalid' and x->>'hash' = h3;
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' a synced change is never sent out again (no loop)');

  r := public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', t || '-staff@example.invalid', 'hash', h1, 'changed_at', now() - interval '1 hour'));
  select encrypted_password = h3 into ok from auth.users where id = stf;
  out := out || ((case when r->>'applied' = 'false' and r->>'reason' = 'older' and ok then 'PASS' else 'FAIL' end) || ' an older change is refused and the hash stays ' || r::text);
  update auth.users set encrypted_password = h2 where id = stf;   -- changed here after the sync
  r := public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', t || '-staff@example.invalid', 'hash', h1, 'changed_at', now() - interval '1 second'));
  select encrypted_password = h2 into ok from auth.users where id = stf;
  out := out || ((case when r->>'applied' = 'false' and ok then 'PASS' else 'FAIL' end) || ' a change made here later wins over an older synced one');

  select banned_until into ban from auth.users where id = held;
  r := public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', t || '-held@example.invalid', 'hash', h3, 'changed_at', clock_timestamp()));
  select encrypted_password = h3 and banned_until is not distinct from ban into ok from auth.users where id = held;
  out := out || ((case when r->>'applied' = 'true' and ok then 'PASS' else 'FAIL' end) || ' a login on hold gets the password but stays on hold');

  begin perform public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', t || '-owner@example.invalid', 'hash', 'plain-text', 'changed_at', now())); msg := 'no error';
  exception when others then msg := sqlerrm; end;
  out := out || ((case when msg = 'That is not a password hash.' then 'PASS' else 'FAIL' end) || ' a non-bcrypt value is refused: ' || msg);
  begin perform public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', t || '-owner@example.invalid', 'hash', h3, 'changed_at', now() + interval '1 day')); msg := 'no error';
  exception when others then msg := sqlerrm; end;
  out := out || ((case when msg = 'changed_at is not a time.' then 'PASS' else 'FAIL' end) || ' a time in the future is refused: ' || msg);

  -- ---------- password_changes { all } (dry run) ----------
  r := public.hub_call(tok, 'password_changes', '{"all": true}'::jsonb);
  select count(*) into n from jsonb_array_elements(r->'logins') x where x->>'email' like t || '%';
  out := out || ((case when n = 3 then 'PASS' else 'FAIL' end) || ' all: the 3 confirmed test logins listed (' || n || ')');
  out := out || ((case when (r->'logins')::text !~ '\$2[aby]\$' and (r->'logins')::text !~ '"hash"' then 'PASS' else 'FAIL' end) || ' all: no hashes in the list');
  select count(*) into n from jsonb_array_elements(r->'logins') x where x->>'email' like '%@devices.%';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' all: device sign-ins are not people (not listed)');
  select count(*) into n from hub_private.pw_changes where email like '%@devices.%';
  out := out || ((case when n = 0 then 'PASS' else 'FAIL' end) || ' a device sign-in is never recorded');
  r := public.hub_call(tok, 'set_password_hash', jsonb_build_object('email', 'dev_' || replace(t, '-', '') || '@devices.label.proviewcrm.co.uk', 'hash', h3, 'changed_at', now()));
  out := out || ((case when r->>'applied' = 'false' and r->>'reason' = 'device' then 'PASS' else 'FAIL' end) || ' set_password_hash leaves a device sign-in alone ' || r::text);

  -- ---------- other hub actions still answer ----------
  begin perform public.hub_call(tok, 'list', '{}'::jsonb); msg := 'ok';
  exception when others then msg := sqlerrm; end;
  out := out || ((case when msg = 'ok' then 'PASS' else 'FAIL' end) || ' hub_call list still works: ' || msg);
  begin perform public.hub_call(tok, 'no_such_action', '{}'::jsonb); msg := 'no error';
  exception when others then msg := sqlerrm; end;
  out := out || ((case when msg <> 'no error' and msg not like '%pw_hub%' then 'PASS' else 'FAIL' end) || ' an unknown action is still refused by hub_call itself: ' || msg);

  -- ---------- sso_entitled: staff admitted, on hold refused ----------
  insert into public.pl_orgs (name) values (t || ' business') returning id into biz;
  insert into public.pl_members (org_id, email, role) values (biz, t || '-owner@example.invalid', 'owner'), (biz, t || '-staff@example.invalid', 'manager'), (biz, t || '-held@example.invalid', 'manager');
  r := public.sso_entitled(t || '-staff@example.invalid');
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' staff member: dashboard hand-off admitted ' || r::text);
  r := public.sso_entitled(t || '-owner@example.invalid');
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' owner: dashboard hand-off admitted ' || r::text);
  r := public.sso_entitled(t || '-held@example.invalid');
  out := out || ((case when not (r->>'ok')::boolean and r->>'reason' ~* 'on hold' then 'PASS' else 'FAIL' end) || ' login on hold: refused ' || r::text);
  r := public.sso_entitled(t || '-stranger@example.invalid');
  out := out || ((case when (r->>'ok')::boolean and (r->>'create')::boolean then 'PASS' else 'FAIL' end) || ' email not in any business: admitted with a new login, as before (Label self sign-up) ' || r::text);

  raise exception E'one password test (015_one_password.sql): %/% PASS\n%',
    (select count(*) from unnest(out) x where x like 'PASS%'), array_length(out, 1), array_to_string(out, E'\n');
end $test$;
