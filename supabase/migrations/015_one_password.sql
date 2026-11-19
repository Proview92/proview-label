-- 015_one_password.sql: one password on every Proview site (owner, 19 Nov 2026; /home/claude/ONE_PASSWORD_SPEC.md).
-- Proview Label (Supabase fiqoirnlmhjzicvktdwa). The licence portal's licence-hub (action password_sync, every minute) copies a
-- password set or changed on any Proview site to every other site where that email has a login, and to the Proview
-- dashboard account. It moves only the bcrypt hash Supabase Auth keeps, through hub_call (hub token), never a password.
--  1. hub_private.pw_changes + a trigger on auth.users: which logins here set or changed their password, and when.
--  2. hub_call 'password_changes' and 'set_password_hash' (the hub token is checked, as for every hub action).
--     Sync never makes a login here, never deletes one, and leaves on hold (banned) and switched-off logins as they are.
--  3. sso_entitled: the dashboard hand-off admits every member of a business, staff too; on hold stays refused.
-- Not applied. Safe to run more than once.

-- ---------- 1. Password changes of this project's logins ----------
-- One row per password set or changed here, and per new login. Only the bcrypt hash Supabase Auth already keeps
-- (auth.users.encrypted_password); never a password. Private: only the functions below read it.
--   source  'user' = changed here (the app, a reset link, the Users panel's Change password, a new login)
--           'sync' = copied here by set_password_hash; password_changes never sends these out again (no loops)
--   kind    'set'  = a password was set or changed     'new' = a login was created (hash may be empty)
create schema if not exists hub_private;
create table if not exists hub_private.pw_changes (
  id         bigserial primary key,
  email      text not null,
  hash       text,
  changed_at timestamptz not null default clock_timestamp(),
  source     text not null default 'user' check (source in ('user', 'sync')),
  kind       text not null default 'set' check (kind in ('set', 'new'))
);
create index if not exists pw_changes_email_idx on hub_private.pw_changes (email, changed_at desc);
create index if not exists pw_changes_at_idx on hub_private.pw_changes (changed_at, id);
revoke all on table hub_private.pw_changes from public, anon, authenticated;
revoke all on sequence hub_private.pw_changes_id_seq from public, anon, authenticated;

-- after insert / after update of encrypted_password on auth.users. A change made by set_password_hash (it sets
-- proview.pw_sync for its own transaction) is recorded by set_password_hash itself, as 'sync'.
create or replace function hub_private.pw_track() returns trigger
language plpgsql security definer set search_path = public as $$
declare em text := lower(trim(coalesce(new.email, ''))); h text := new.encrypted_password;
begin
  -- no email, anonymous, or a device sign-in (Label handhelds: dev_…@devices.label.proviewcrm.co.uk): not a person
  if em = '' or coalesce(new.is_anonymous, false) or em ~ '@devices\.([a-z0-9-]+\.)*proviewcrm\.co\.uk$' then return null; end if;
  if coalesce(current_setting('proview.pw_sync', true), '') <> '' then return null; end if;
  if h is null or h !~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' then h := null; end if;
  -- a temporary password an admin set (Signage's "Reset password" to 123456, must be changed at the next sign-in) or
  -- the random one it is replaced with when it expires: never copied to other sites
  if coalesce(new.raw_app_meta_data->>'must_change_password', '') = 'true' or coalesce(new.raw_app_meta_data->>'temp_password_expired', '') = 'true' then
    h := null;
    if tg_op = 'UPDATE' then return null; end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.encrypted_password is not distinct from old.encrypted_password or h is null then return null; end if;
    insert into hub_private.pw_changes (email, hash, source, kind) values (em, h, 'user', 'set');
  else
    insert into hub_private.pw_changes (email, hash, source, kind) values (em, h, 'user', 'new');
  end if;
  return null;
end $$;
revoke all on function hub_private.pw_track() from public, anon, authenticated;
drop trigger if exists pw_track on auth.users;
create trigger pw_track after insert or update of encrypted_password on auth.users
  for each row execute function hub_private.pw_track();

-- ---------- 2. The two hub actions (licence-hub's password_sync is the only caller) ----------
--   password_changes { since?, limit? }  -> { ok, changes: [{ email, hash, changed_at, kind }], more }
--        changes made HERE (source 'user') after since, of confirmed logins, oldest first (at most 1000)
--   password_changes { all: true }       -> { ok, logins: [{ email, has_password, held_at }] }   (no hashes; dry run)
--   set_password_hash { email, hash, changed_at } -> { ok, email, applied, reason? }
--        only when changed_at is newer than the newest change this project holds for that email. Never makes a
--        login; keeps email_confirmed_at, bans (on hold) and memberships exactly as they are; clears recovery tokens.
create or replace function hub_private.pw_hub(p_token text, p_action text, p_args jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  em text; h text; at timestamptz; held timestamptz; since timestamptz; lim int; n int; out jsonb; uid uuid; cur text;
begin
  if p_token is null or (select token_sha256 from hub_private.config where id = 1) is null
     or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  p_args := coalesce(p_args, '{}'::jsonb);

  if p_action = 'password_changes' then
    if coalesce((p_args->>'all')::boolean, false) then
      select coalesce(jsonb_agg(jsonb_build_object('email', q.e, 'has_password', q.hp, 'held_at', q.held) order by q.e), '[]'::jsonb) into out
      from (select distinct on (lower(u.email)) lower(u.email) as e,
                   coalesce(u.encrypted_password ~ '^\$2[aby]\$', false) as hp,
                   (select max(c.changed_at) from hub_private.pw_changes c where c.email = lower(u.email)) as held
              from auth.users u
             where u.email is not null and not coalesce(u.is_anonymous, false) and u.email_confirmed_at is not null
               and lower(u.email) !~ '@devices\.([a-z0-9-]+\.)*proviewcrm\.co\.uk$'
             order by lower(u.email), u.created_at) q;
      return jsonb_build_object('ok', true, 'logins', out);
    end if;
    begin since := nullif(p_args->>'since', '')::timestamptz; exception when others then raise exception 'since is not a time.'; end;
    lim := least(greatest(coalesce(nullif(p_args->>'limit', '')::int, 500), 1), 1000);
    select coalesce(jsonb_agg(jsonb_build_object('email', q.email, 'hash', q.hash, 'changed_at', q.changed_at, 'kind', q.kind) order by q.changed_at, q.id), '[]'::jsonb),
           count(*) into out, n
    from (select c.id, c.email, c.hash, c.changed_at, c.kind from hub_private.pw_changes c
           where c.source = 'user' and (since is null or c.changed_at > since)
             and exists (select 1 from auth.users u where lower(u.email) = c.email and u.email_confirmed_at is not null
                                                     and not coalesce(u.is_anonymous, false))
           order by c.changed_at, c.id limit lim) q;
    return jsonb_build_object('ok', true, 'changes', out, 'more', n >= lim);
  end if;

  if p_action = 'set_password_hash' then
    em := lower(trim(coalesce(p_args->>'email', '')));
    h  := p_args->>'hash';
    if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
    if em ~ '@devices\.([a-z0-9-]+\.)*proviewcrm\.co\.uk$' then return jsonb_build_object('ok', true, 'email', em, 'applied', false, 'reason', 'device'); end if;
    if h is null or h !~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' then raise exception 'That is not a password hash.'; end if;
    begin at := (p_args->>'changed_at')::timestamptz; exception when others then raise exception 'changed_at is not a time.'; end;
    if at is null or at > now() + interval '5 minutes' then raise exception 'changed_at is not a time.'; end if;
    select id, encrypted_password into uid, cur from auth.users
     where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
    if uid is null then return jsonb_build_object('ok', true, 'email', em, 'applied', false, 'reason', 'no login'); end if;
    perform pg_advisory_xact_lock(hashtext('pw:' || em));
    select max(changed_at) into held from hub_private.pw_changes where email = em;
    if held is not null and held >= at then return jsonb_build_object('ok', true, 'email', em, 'applied', false, 'reason', 'older'); end if;
    perform set_config('proview.pw_sync', uid::text, true);
    update auth.users set encrypted_password = h, recovery_token = '', updated_at = now()
     where lower(email) = em and not coalesce(is_anonymous, false) and encrypted_password is distinct from h;
    update auth.users set recovery_token = '' where lower(email) = em and not coalesce(is_anonymous, false) and coalesce(recovery_token, '') <> '';
    if to_regclass('auth.one_time_tokens') is not null then
      execute 'delete from auth.one_time_tokens t using auth.users u where u.id = t.user_id and lower(u.email) = $1 and t.token_type::text = ''recovery_token'''
        using em;
    end if;
    perform set_config('proview.pw_sync', '', true);
    insert into hub_private.pw_changes (email, hash, changed_at, source, kind) values (em, h, at, 'sync', 'set');
    return jsonb_build_object('ok', true, 'email', em, 'applied', true);
  end if;
  raise exception 'Unknown action.';
end $$;
revoke all on function hub_private.pw_hub(text, text, jsonb) from public, anon, authenticated;

-- hub_call answers the two new actions first (the token is checked inside pw_hub). The live hub_call is patched
-- rather than rewritten, so every other action stays exactly as it is.
do $p$ declare d text; begin
  d := pg_get_functiondef('public.hub_call(text,text,jsonb)'::regprocedure);
  if position('hub_private.pw_hub' in d) = 0 then
    d := regexp_replace(d, E'\\nbegin[ \\t]*\\n', E'\nbegin\n  if p_action in (''password_changes'', ''set_password_hash'') then return hub_private.pw_hub(p_token, p_action, p_args); end if;\n');
    if position('hub_private.pw_hub' in d) = 0 then raise exception 'one password: could not add the password actions to hub_call'; end if;
    execute d;
  end if;
end $p$;

-- ---------- 3. Dashboard hand-off (sso-login) ----------
-- Label already lets every back-office login of a business open it from the Proview dashboard (device staff sign in
-- on the handheld with a PIN and are not changed). Added: a login on hold (banned) stays refused.
create or replace function public.sso_entitled(p_email text)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; ban timestamptz; em text := lower(trim(p_email));
begin
  select id, banned_until into uid, ban from auth.users
   where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
  if ban > now() then
    return jsonb_build_object('ok', false, 'reason', 'This Label login is on hold. Contact Proview.');
  end if;
  if exists (select 1 from public.pl_masters where email = em)
     or exists (select 1 from public.pl_members m join public.pl_orgs o on o.id = m.org_id where m.email = em and not o.suspended)
     or not exists (select 1 from public.pl_members where email = em) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Label account for this email.');
end $$;
