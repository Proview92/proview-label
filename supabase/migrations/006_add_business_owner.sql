-- 006: "+ Add business" asks for the owner's login too (owner, 10 Nov 2026, ADD_BUSINESS_SPEC.md; same as
-- Proview Signage migration 038 add_business / add_user).
--
-- pl_add_business(business, name, email, mobile, password), master only, all-or-nothing:
--   * creates the business (pl_orgs, licensed: no trial, exactly like pl_create_org) and a location with the same
--     name (a 'sites' record, the same shape pl_start_trial makes);
--   * new email: creates a ready-to-use login (email confirmed, password set, name + mobile kept, no email sent);
--   * email that already has a login: links that login, and NEVER changes its password;
--   * either way the person becomes the business's Owner (pl_members role 'owner' = Owner / Admin).
--   Any error (bad email, short password, ...) raises, so the business and location are undone too.
-- pl_create_org stays as it is (nothing calls it after this, but older open tabs still work).
-- Not affected by migration 004 (x-pl-org): this makes a new business, so there is no business open yet.

alter table public.pl_members add column if not exists mobile text;

create or replace function public.pl_add_business(p_business text, p_name text, p_email text, p_mobile text, p_password text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  bn  text := trim(coalesce(p_business, ''));
  nm  text := trim(coalesce(p_name, ''));
  em  text := lower(trim(coalesce(p_email, '')));
  mob text := nullif(trim(coalesce(p_mobile, '')), '');
  oid text; sid text; uid uuid; existing boolean := false;
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can add businesses.'; end if;
  if length(bn) < 2 or length(bn) > 120 then raise exception 'Enter the business name.'; end if;
  if length(nm) < 2 then raise exception 'Enter the owner''s name.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;

  insert into public.pl_orgs(name) values (bn) returning id into oid;
  sid := 'site_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  insert into public.pl_records(id, org_id, site_id, kind, data)
    values (sid, oid, sid, 'sites', jsonb_build_object('id', sid, 'orgId', oid, 'name', bn, 'address', '', 'region', ''));

  select id into uid from auth.users where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
  if uid is not null then
    existing := true;   -- already has a login: add them to this business, but never touch their password
  else
    if length(coalesce(p_password, '')) < 6 then raise exception 'The password needs at least 6 characters.'; end if;
    uid := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change, email_change_token_new)
    values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', em,
            extensions.crypt(p_password, extensions.gen_salt('bf', 10)), now(),
            '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_strip_nulls(jsonb_build_object('name', nm, 'full_name', nm, 'mobile', mob)), now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
            jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true, 'phone_verified', false), now(), now(), now());
  end if;

  insert into public.pl_members(org_id, email, user_id, name, mobile, role)
    values (oid, em, uid, nm, mob, 'owner');

  return jsonb_build_object('org_id', oid, 'site_id', sid, 'user_id', uid, 'email', em, 'existing', existing);
end;
$$;
revoke all on function public.pl_add_business(text, text, text, text, text) from public, anon;
grant execute on function public.pl_add_business(text, text, text, text, text) to authenticated;
