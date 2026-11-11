-- 008: the licence portal's "New customer" can add the business here too (NEW_CUSTOMER_MULTIAPP_SPEC, 11 Nov 2026).
--
-- The licence hub (edge function licence-hub) calls hub_call(token, 'add_business', args) with
-- args { business, name, email, mobile, password, contact_email? } and gets pl_add_business's result plus account_id.
-- It runs the master's own "+ Add business", public.pl_add_business (migration 006), unchanged, so it behaves exactly
-- the same: the same checks and messages, all or nothing, no email sent, an existing login keeps its password, and the
-- new business gets whatever licence state pl_add_business gives it (none, once the no-trial migration is in).
-- Only "who may call" differs: the hub token instead of the master's sign-in. For this one call the request runs as
-- this app's master account (pl_masters), which pl_add_business checks for, and is put back straight after.
-- Label had no hub yet: this also adds hub_private (token hash) and a read-only 'list' for the portal's sync.
-- Safe to run more than once, and in any order with the no-trial migration.

-- 1) Label's hub (new): the private token store and the base actions. Until the portal's token hash is set
--    (go-live step, see the licence portal's 20261112 migration) every hub call is refused.
create schema if not exists hub_private;
revoke all on schema hub_private from public, anon, authenticated;
create table if not exists hub_private.config(id int primary key check (id = 1), token_sha256 text, plans jsonb not null default '{}'::jsonb);
insert into hub_private.config(id) values (1) on conflict (id) do nothing;
revoke all on table hub_private.config from public, anon, authenticated;

-- 'list': the businesses, for the portal's sync and linking. A Label licence belongs to the business (pl_orgs
-- suspended / trial_ends_at), which the portal cannot set yet, so no units are listed and 'set' is refused.
create or replace function hub_private.hub_call_base(p_token text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
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
      'units', '[]'::jsonb);
  elsif p_action = 'set' then
    raise exception 'Proview Label licences can''t be set from the licence portal yet.';
  else
    raise exception 'unknown action %', p_action;
  end if;
end;
$$;
revoke all on function hub_private.hub_call_base(text, text, jsonb) from public, anon, authenticated;

-- 2) hub_call: 'add_business' here, every other action exactly as before.
create or replace function public.hub_call(p_token text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  r jsonb; mu uuid; me text;
  ce text := nullif(lower(trim(coalesce(p_args->>'contact_email', ''))), '');
  c_claims text := current_setting('request.jwt.claims', true);
  c_sub    text := current_setting('request.jwt.claim.sub', true);
  c_claim  text := current_setting('request.jwt.claim', true);
begin
  if p_action is distinct from 'add_business' then
    return hub_private.hub_call_base(p_token, p_action, p_args);
  end if;
  if p_token is null or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  if ce is not null and ce !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid contact email, or leave it empty.'; end if;

  -- the master's own Add business, run as the master (pl_masters) for this one call
  select m.user_id, lower(u.email) into mu, me from public.pl_masters m join auth.users u on u.id = m.user_id
   order by u.created_at limit 1;
  if mu is null and me is null then raise exception 'This app has no Proview master account to add the business with.'; end if;
  perform set_config('request.jwt.claims', jsonb_strip_nulls(jsonb_build_object('sub', mu, 'email', me, 'role', 'authenticated',
                     'aud', 'authenticated', 'is_anonymous', false))::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(mu::text, ''), true);
  perform set_config('request.jwt.claim', '', true);
  r := public.pl_add_business(p_args->>'business', p_args->>'name', p_args->>'email', p_args->>'mobile', p_args->>'password');
  perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
  perform set_config('request.jwt.claim', coalesce(c_claim, ''), true);

  -- Label has no contact email column: the portal links by account_id, and 'list' reports the owner's email
  return r || jsonb_build_object('account_id', r->>'org_id');
end;
$$;
revoke all on function public.hub_call(text, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.hub_call(text, text, jsonb) to anon, authenticated;
