-- Test for 016_sso_members_only.sql. Paste into the SQL editor of proview-label (fiqoirnlmhjzicvktdwa) AFTER the
-- migration. Throw-away rows only (emails under example.invalid); it ALWAYS ends with an exception listing PASS / FAIL,
-- which rolls everything back.
do $t$
declare out text[] := '{}'; t text := 'zz016-' || substr(md5(random()::text), 1, 8); o text; s text; r jsonb;
begin
  insert into pl_orgs(name) values (t || ' biz') returning id into o;
  insert into pl_orgs(name, suspended) values (t || ' paused', true) returning id into s;
  insert into pl_members(org_id, email, role) values (o, t || '-member@example.invalid', 'manager'), (s, t || '-paused@example.invalid', 'owner');

  r := public.sso_entitled(t || '-stranger@example.invalid');
  out := out || ((case when not (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' email with no Label business: refused ' || r::text);
  r := public.sso_entitled(t || '-member@example.invalid');
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' member of an active business: allowed');
  r := public.sso_entitled(upper(t) || '-MEMBER@example.invalid ');
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' case and spaces ignored');
  r := public.sso_entitled(t || '-paused@example.invalid');
  out := out || ((case when not (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' member of a suspended business only: refused');
  r := public.sso_entitled((select email from pl_masters limit 1));
  out := out || ((case when (r->>'ok')::boolean then 'PASS' else 'FAIL' end) || ' the Label master: allowed');
  out := out || ((case when not has_function_privilege('authenticated', 'public.sso_entitled(text)', 'execute')
                       and has_function_privilege('service_role', 'public.sso_entitled(text)', 'execute') then 'PASS' else 'FAIL' end) || ' only service_role may call it');

  raise exception E'016 TEST RESULT (rolled back): %/% PASS\n%',
    (select count(*) from unnest(out) x where x like 'PASS%'), array_length(out, 1), array_to_string(out, E'\n');
end $t$;
