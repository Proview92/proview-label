-- Proview Label: businesses, sites, back-office logins and synced records.
-- Applied to Supabase project proview-label (fiqoirnlmhjzicvktdwa, London) on 7 Nov 2026.
create extension if not exists pgcrypto;

create table public.pl_orgs (
  id text primary key default 'org_' || replace(gen_random_uuid()::text,'-',''),
  name text not null check (length(trim(name)) between 1 and 120),
  settings jsonb not null default '{}'::jsonb,
  suspended boolean not null default false,
  created_at timestamptz not null default now()
);
-- Proview master admins (claimed by email the first time that address signs in)
create table public.pl_masters (
  email text primary key check (email = lower(email)),
  user_id uuid unique references auth.users(id) on delete set null,
  added_at timestamptz not null default now()
);
-- Back-office logins per business. Device staff (PINs) live in pl_records kind 'users'.
create table public.pl_members (
  id text primary key default 'mem_' || replace(gen_random_uuid()::text,'-',''),
  org_id text not null references public.pl_orgs(id) on delete cascade,
  email text not null check (email = lower(email)),
  user_id uuid references auth.users(id) on delete set null,
  name text not null default '',
  role text not null check (role in ('owner','admin','manager')),
  site_ids text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (org_id, email)
);
create index pl_members_user on public.pl_members(user_id);
create index pl_members_email on public.pl_members(email);
create table public.pl_records (
  id text primary key,
  org_id text not null references public.pl_orgs(id) on delete cascade,
  site_id text,
  kind text not null check (kind in ('sites','categories','products','rules','users','labels','wastage','orders','devices','audit')),
  data jsonb not null,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create index pl_records_sync on public.pl_records(org_id, updated_at);
create index pl_records_site on public.pl_records(site_id);
create table public.pl_sso_used (jti text primary key, email text, at timestamptz not null default now());

-- ---------- access helpers ----------
create or replace function public.pl_my_email() returns text language sql stable security definer set search_path = public, auth as $$
  select lower(email) from auth.users where id = auth.uid() and email_confirmed_at is not null $$;
create or replace function public.pl_is_master() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from public.pl_masters where user_id = auth.uid()) $$;
create or replace function public.pl_member(p_org text) returns public.pl_members language sql stable security definer set search_path = public as $$
  select * from public.pl_members where org_id = p_org and user_id = auth.uid() limit 1 $$;
create or replace function public.pl_can_read(p_org text, p_site text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return true; end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;
create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return true; end if;
  if exists (select 1 from public.pl_orgs where id = p_org and suspended) then return false; end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;
create or replace function public.pl_is_org_admin(p_org text) returns boolean language sql stable security definer set search_path = public as $$
  select public.pl_is_master() or coalesce((public.pl_member(p_org)).role in ('owner','admin'), false) $$;
create or replace function public.pl_touch() returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger pl_records_touch before insert or update on public.pl_records for each row execute function public.pl_touch();

-- ---------- row-level security ----------
alter table public.pl_orgs enable row level security;
alter table public.pl_masters enable row level security;
alter table public.pl_members enable row level security;
alter table public.pl_records enable row level security;
alter table public.pl_sso_used enable row level security;
revoke all on public.pl_sso_used from public, anon, authenticated;
grant all on public.pl_sso_used to service_role;
create policy "orgs read" on public.pl_orgs for select to authenticated
  using (public.pl_is_master() or exists (select 1 from public.pl_members m where m.org_id = pl_orgs.id and m.user_id = auth.uid()));
create policy "orgs master insert" on public.pl_orgs for insert to authenticated with check (public.pl_is_master());
create policy "orgs admin update" on public.pl_orgs for update to authenticated using (public.pl_is_org_admin(id)) with check (public.pl_is_org_admin(id));
create policy "masters read self" on public.pl_masters for select to authenticated using (user_id = auth.uid() or public.pl_is_master());
create policy "members read" on public.pl_members for select to authenticated
  using (user_id = auth.uid() or public.pl_is_master() or (public.pl_member(org_id)).id is not null);
create policy "members admin write" on public.pl_members for insert to authenticated
  with check (public.pl_is_org_admin(org_id) and (role <> 'owner' or public.pl_is_master() or (public.pl_member(org_id)).role = 'owner'));
create policy "members admin update" on public.pl_members for update to authenticated
  using (public.pl_is_org_admin(org_id)) with check (public.pl_is_org_admin(org_id) and (role <> 'owner' or public.pl_is_master() or (public.pl_member(org_id)).role = 'owner'));
create policy "members admin delete" on public.pl_members for delete to authenticated using (public.pl_is_org_admin(org_id) and user_id is distinct from auth.uid());
create policy "records read" on public.pl_records for select to authenticated using (public.pl_can_read(org_id, site_id));
create policy "records insert" on public.pl_records for insert to authenticated with check (public.pl_can_write(org_id, site_id, kind));
create policy "records update" on public.pl_records for update to authenticated
  using (public.pl_can_write(org_id, site_id, kind)) with check (public.pl_can_write(org_id, site_id, kind));

-- ---------- linking logins to invites ----------
create or replace function public.pl_link(p_uid uuid, p_email text) returns void language sql security definer set search_path = public as $$
  update public.pl_members set user_id = p_uid where lower(email) = lower(p_email) and user_id is null;
  update public.pl_masters set user_id = p_uid where email = lower(p_email) and user_id is null; $$;
create or replace function public.pl_on_user() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.pl_link(new.id, new.email); return new; end $$;
create trigger pl_on_user after insert or update of email_confirmed_at on auth.users
  for each row when (new.email_confirmed_at is not null) execute function public.pl_on_user();
create or replace function public.pl_on_invite() returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  select id into u from auth.users where lower(email) = lower(new.email) and email_confirmed_at is not null limit 1;
  if u is not null then perform public.pl_link(u, new.email); end if;
  return null;
end $$;
create trigger pl_on_member after insert or update of email on public.pl_members for each row execute function public.pl_on_invite();
create trigger pl_on_master after insert or update of email on public.pl_masters for each row execute function public.pl_on_invite();

create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean;
begin
  if auth.uid() is null then return null; end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  return jsonb_build_object('email', em, 'master', is_m,
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               where is_m or m.id is not null), '[]'::jsonb));
end $$;
create or replace function public.pl_create_org(p_name text, p_owner_email text default null, p_owner_name text default '') returns text
language plpgsql security definer set search_path = public as $$
declare oid text;
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can add businesses.'; end if;
  insert into public.pl_orgs(name) values (trim(p_name)) returning id into oid;
  if coalesce(trim(p_owner_email),'') <> '' then
    insert into public.pl_members(org_id, email, name, role) values (oid, lower(trim(p_owner_email)), coalesce(p_owner_name,''), 'owner');
  end if;
  return oid;
end $$;
-- used by the sso-login edge function only
create or replace function public.sso_entitled(p_email text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; em text := lower(trim(p_email));
begin
  select id into uid from auth.users where lower(email) = em order by created_at limit 1;
  if exists (select 1 from public.pl_masters where email = em)
     or exists (select 1 from public.pl_members m join public.pl_orgs o on o.id = m.org_id where m.email = em and not o.suspended) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Label account for this email.');
end $$;

revoke execute on function public.sso_entitled(text), public.pl_link(uuid, text), public.pl_on_user(), public.pl_on_invite(), public.pl_touch() from public, anon, authenticated;
grant execute on function public.sso_entitled(text) to service_role;
revoke execute on function public.pl_whoami(), public.pl_create_org(text, text, text), public.pl_my_email(), public.pl_is_master(), public.pl_member(text),
  public.pl_can_read(text, text), public.pl_can_write(text, text, text), public.pl_is_org_admin(text) from public, anon;
grant execute on function public.pl_whoami(), public.pl_create_org(text, text, text), public.pl_my_email(), public.pl_is_master(), public.pl_member(text),
  public.pl_can_read(text, text), public.pl_can_write(text, text, text), public.pl_is_org_admin(text) to authenticated;
grant select, insert, update on public.pl_records to authenticated;
grant select, insert, update, delete on public.pl_members to authenticated;
grant select, insert, update on public.pl_orgs to authenticated;
grant select on public.pl_masters to authenticated;

insert into public.pl_masters(email) values ('altun@proviewtech.co.uk') on conflict do nothing;
alter publication supabase_realtime add table public.pl_records;
