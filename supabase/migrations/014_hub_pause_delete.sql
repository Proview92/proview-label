-- 014: the licence portal can pause / resume a business and delete it completely (owner, 12 Nov 2026).
--   hub_call 'suspend' { account_id, suspended: true|false } -> { ok, account_id, suspended }
--     sets pl_orgs.suspended: a suspended business is fully locked (pl_can_write, pl_handheld_open, pl_whoami).
--   hub_call 'delete_account' { account_id } -> { ok, account_id, deleted }
--     deletes the business and everything in it (records, members, handhelds and their licences, pairings, trials;
--     pl_orgs cascades) and the handhelds' own sign-ins. People's logins are kept (they may belong to other businesses).
-- The portal's licence time freeze is done by the portal (it adds the paused days back on resume).
create or replace function hub_private.pl_hub_admin(p_action text, p_args jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.pl_orgs; s boolean; devs uuid[];
begin
  select * into o from public.pl_orgs where id = coalesce(p_args->>'account_id', '');
  if p_action = 'suspend' then
    if o.id is null then raise exception 'Business not found.'; end if;
    s := coalesce((p_args->>'suspended')::boolean, true);
    update public.pl_orgs set suspended = s where id = o.id;
    return jsonb_build_object('ok', true, 'account_id', o.id, 'suspended', s);
  end if;
  -- delete_account: pressing it again after it worked is fine
  if o.id is null then return jsonb_build_object('ok', true, 'account_id', p_args->>'account_id', 'deleted', true, 'already', true); end if;
  select coalesce(array_agg(user_id) filter (where user_id is not null), '{}') into devs from public.pl_devices where org_id = o.id;
  delete from public.pl_trials where org_id = o.id;
  delete from public.pl_orgs where id = o.id;
  delete from auth.users where id = any(devs);
  return jsonb_build_object('ok', true, 'account_id', o.id, 'deleted', true);
end $$;
revoke all on function hub_private.pl_hub_admin(text, jsonb) from public, anon, authenticated;

do $p$ declare d text; begin
  d := pg_get_functiondef('hub_private.hub_call_base(text,text,jsonb)'::regprocedure);
  if position('pl_hub_admin' in d) = 0 then
    execute replace(d, '  elsif p_action = ''link'' then',
      '  elsif p_action in (''suspend'', ''delete_account'') then
    return hub_private.pl_hub_admin(p_action, p_args);
  elsif p_action = ''link'' then');
  end if;
end $p$;
