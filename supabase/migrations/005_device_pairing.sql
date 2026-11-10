-- Handheld pairing (like Proview Signage): no email or password on the handheld.
--  1. On first open the handheld makes a random secret, calls pl_pair_start(secret) and shows the
--     6-character code (and a QR code linking to the back-office with the code filled in).
--  2. A back-office login enters the code on Locations & devices → Pair handheld, picks the location,
--     a name and Easy/Detailed mode: pl_pair_claim.
--  3. The handheld keeps asking the pl-device-pair edge function (with its secret). Once claimed, the
--     function makes a login for that handheld only and hands it over; the handheld signs in with it.
-- A paired handheld can read and write its own business's records for its own location only.
-- Removing it in the back-office (pl_device_remove) cuts its access at once.

create table public.pl_pairings (
  code text primary key,
  secret_hash text not null unique,        -- sha256 of the handheld's secret (the secret never leaves the handheld except to the edge function)
  device_id text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes',
  org_id text references public.pl_orgs(id) on delete cascade,
  site_id text,
  name text,
  mode text check (mode in ('easy','detailed')),
  claimed_by uuid,
  claimed_at timestamptz,
  user_id uuid
);
create table public.pl_devices (
  id text primary key,
  user_id uuid unique references auth.users(id) on delete cascade,
  org_id text not null references public.pl_orgs(id) on delete cascade,
  site_id text not null,
  name text not null default 'Handheld' check (length(trim(name)) between 1 and 60),
  mode text not null default 'easy' check (mode in ('easy','detailed')),
  paired_at timestamptz not null default now(),
  paired_by uuid
);
create index pl_devices_org on public.pl_devices(org_id);
alter table public.pl_pairings enable row level security;
alter table public.pl_devices enable row level security;
revoke all on public.pl_pairings from public, anon, authenticated;
grant all on public.pl_pairings to service_role;
revoke all on public.pl_devices from public, anon, authenticated;
grant select on public.pl_devices to authenticated;
grant all on public.pl_devices to service_role;

-- the paired handheld making this request (null for people)
create or replace function public.pl_device_me() returns public.pl_devices language sql stable security definer set search_path = public as $$
  select * from public.pl_devices where user_id = auth.uid() limit 1 $$;

-- ---------- access rules: add paired handhelds ----------
create or replace function public.pl_can_read(p_org text, p_site text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; d public.pl_devices;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return public.pl_master_in(p_org); end if;
  d := public.pl_device_me();
  if d.id is not null then return p_org = d.org_id and (p_site is null or p_site = d.site_id); end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; d public.pl_devices; f text;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return public.pl_master_in(p_org); end if;   -- one business per request
  if public.pl_org_locked(p_org) then return false; end if;    -- suspended or trial ended
  d := public.pl_device_me();
  if d.id is not null then                                     -- a handheld: its own location, never sites
    return p_org = d.org_id and p_kind <> 'sites' and (p_site is null or p_site = d.site_id);
  end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;              -- managers can't add or edit sites
  f := public.pl_write_feature(p_kind);
  if f is not null and not coalesce((m.features ->> f)::boolean, true) then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

-- back-office: who can see a handheld
create policy "devices read" on public.pl_devices for select to authenticated
  using (user_id = auth.uid() or (public.pl_device_me()).id is null and public.pl_can_read(org_id, site_id));

-- whoami: a handheld gets its one business, its location, name and mode
create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean; d public.pl_devices;
begin
  if auth.uid() is null then return null; end if;
  d := public.pl_device_me();
  if d.id is not null then
    return jsonb_build_object('email', null, 'master', false, 'trial_used', true,
      'device', jsonb_build_object('id', d.id, 'name', d.name, 'mode', d.mode, 'site_id', d.site_id, 'org_id', d.org_id),
      'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', o.trial_ends_at,
                 'trial_expired', o.trial_ends_at is not null and o.trial_ends_at < now(),
                 'locked', o.suspended or (o.trial_ends_at is not null and o.trial_ends_at < now()),
                 'role', 'device', 'site_ids', jsonb_build_array(d.site_id), 'member_id', null, 'features', '{}'::jsonb))
               from public.pl_orgs o where o.id = d.org_id), '[]'::jsonb));
  end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  return jsonb_build_object('email', em, 'master', is_m,
    'trial_used', em is not null and exists (select 1 from public.pl_trials t where t.email = em),
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', o.trial_ends_at,
                 'trial_expired', o.trial_ends_at is not null and o.trial_ends_at < now(),
                 'locked', o.suspended or (o.trial_ends_at is not null and o.trial_ends_at < now()),
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               where is_m or m.id is not null), '[]'::jsonb));
end $$;

-- ---------- pairing ----------
-- handheld, not signed in: get (or keep) a pairing code for this secret
create or replace function public.pl_pair_start(p_secret text) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare h text; p public.pl_pairings; c text; i int; a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if p_secret is null or length(p_secret) < 32 or length(p_secret) > 200 then raise exception 'Bad pairing secret'; end if;
  h := encode(extensions.digest(p_secret, 'sha256'), 'hex');
  delete from public.pl_pairings where expires_at < now();
  select * into p from public.pl_pairings where secret_hash = h;
  if p.code is not null then return jsonb_build_object('code', p.code, 'expires_at', p.expires_at, 'claimed', p.claimed_at is not null); end if;
  if (select count(*) from public.pl_pairings where claimed_at is null) > 2000 then raise exception 'Too many handhelds waiting to pair. Try again in a few minutes.'; end if;
  loop
    c := '';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from public.pl_pairings where code = c);
  end loop;
  insert into public.pl_pairings(code, secret_hash, device_id) values (c, h, 'dev_' || replace(gen_random_uuid()::text, '-', ''))
    returning * into p;
  return jsonb_build_object('code', p.code, 'expires_at', p.expires_at, 'claimed', false);
end $$;

-- back-office: pair the handheld showing this code to a location
create or replace function public.pl_pair_claim(p_code text, p_site text, p_name text, p_mode text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare p public.pl_pairings; o text;
begin
  if auth.uid() is null or (public.pl_device_me()).id is not null then raise exception 'Sign in to the back-office to pair a handheld.'; end if;
  select org_id into o from public.pl_records where kind = 'sites' and id = p_site and not deleted;
  if o is null then raise exception 'Pick a location for this handheld.'; end if;
  if not public.pl_can_write(o, p_site, 'devices') then raise exception 'You can''t add handhelds at this location.'; end if;
  select * into p from public.pl_pairings where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')) and expires_at > now() for update;
  if p.code is null then raise exception 'That code isn''t showing on any handheld. Check the code on the screen and try again.'; end if;
  if p.claimed_at is not null then raise exception 'That handheld has already been paired.'; end if;
  update public.pl_pairings set org_id = o, site_id = p_site, name = coalesce(nullif(trim(p_name), ''), 'Handheld'),
    mode = case when p_mode = 'detailed' then 'detailed' else 'easy' end, claimed_by = auth.uid(), claimed_at = now(),
    expires_at = now() + interval '1 hour' where code = p.code;
  return p.device_id;
end $$;

-- back-office: rename a handheld, move it to another location, or change Easy/Detailed
create or replace function public.pl_device_update(p_id text, p_name text, p_site text, p_mode text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare d public.pl_devices; o text;
begin
  select * into d from public.pl_devices where id = p_id;
  if d.id is null or (public.pl_device_me()).id is not null or not public.pl_can_write(d.org_id, d.site_id, 'devices') then raise exception 'You can''t change this handheld.'; end if;
  if p_site is not null and p_site <> d.site_id then
    select org_id into o from public.pl_records where kind = 'sites' and id = p_site and not deleted;
    if o is distinct from d.org_id or not public.pl_can_write(o, p_site, 'devices') then raise exception 'You can''t move the handheld to that location.'; end if;
  end if;
  update public.pl_devices set name = coalesce(nullif(trim(p_name), ''), name), site_id = coalesce(p_site, site_id),
    mode = case when p_mode in ('easy','detailed') then p_mode else mode end where id = p_id;
end $$;

-- back-office: remove a handheld; it loses access at once and shows the pairing screen again
create or replace function public.pl_device_remove(p_id text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare d public.pl_devices;
begin
  select * into d from public.pl_devices where id = p_id;
  if d.id is null then return; end if;
  -- the handheld itself (Settings → Unpair), or a back-office login allowed at its location
  if not (d.user_id = auth.uid() or ((public.pl_device_me()).id is null and public.pl_can_write(d.org_id, d.site_id, 'devices'))) then raise exception 'You can''t remove this handheld.'; end if;
  delete from public.pl_devices where id = p_id;
  update public.pl_records set deleted = true where kind = 'devices' and id = p_id;
end $$;

-- used by the pl-device-pair edge function only
create or replace function public.pl_auth_uid(p_email text) returns uuid language sql stable security definer set search_path = public, auth as $$
  select id from auth.users where lower(email) = lower(p_email) limit 1 $$;

revoke execute on function public.pl_device_me(), public.pl_pair_start(text), public.pl_pair_claim(text, text, text, text),
  public.pl_device_update(text, text, text, text), public.pl_device_remove(text), public.pl_auth_uid(text) from public, anon, authenticated;
grant execute on function public.pl_pair_start(text) to anon, authenticated;
grant execute on function public.pl_device_me(), public.pl_pair_claim(text, text, text, text), public.pl_device_update(text, text, text, text),
  public.pl_device_remove(text) to authenticated;
grant execute on function public.pl_auth_uid(text) to service_role;
