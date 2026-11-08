-- 004: one business at a time (owner, 8 Nov 2026, ONE_BUSINESS_RULE.md)
--
-- The Proview master may control every business, but only one at a time, exactly like that business's owner.
-- Each request names the business it is for in the x-pl-org header (the back-office sends the business that is
-- open). Without it, or for any other business, the master can only read the All sites list: the businesses
-- (pl_orgs) and their sites and devices. Every other read and every write is refused.
-- Business logins are unchanged: they only ever see the businesses they belong to.

-- the business this request is for (x-pl-org header; null when not sent)
create or replace function public.pl_req_org() returns text language sql stable set search_path = public as $$
  select nullif(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> 'x-pl-org', '') $$;

-- master, working inside this business (named in this request)
create or replace function public.pl_master_in(p_org text) returns boolean language sql stable security definer set search_path = public as $$
  select public.pl_is_master() and p_org is not null and p_org = public.pl_req_org() $$;

create or replace function public.pl_can_read(p_org text, p_site text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return public.pl_master_in(p_org); end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

-- master: the All sites list (sites, devices) of every business; everything else only in the business named
create or replace function public.pl_can_read_kind(p_org text, p_site text, p_kind text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when public.pl_is_master() then (p_kind in ('sites','devices') or public.pl_master_in(p_org))
    else public.pl_can_read(p_org, p_site)
     and (public.pl_read_feature(p_kind) is null or public.pl_has_feature(p_org, public.pl_read_feature(p_kind))) end $$;

create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; f text;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return public.pl_master_in(p_org); end if;   -- one business per request
  if public.pl_org_locked(p_org) then return false; end if;    -- suspended or trial ended
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;              -- managers can't add or edit sites
  f := public.pl_write_feature(p_kind);
  if f is not null and not coalesce((m.features ->> f)::boolean, true) then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

-- owners/admins of a business, or the master working inside it
create or replace function public.pl_is_org_admin(p_org text) returns boolean language sql stable security definer set search_path = public as $$
  select public.pl_master_in(p_org) or coalesce((public.pl_member(p_org)).role in ('owner','admin'), false) $$;

-- back-office logins: the master sees and manages them only inside the business that is open
drop policy if exists "members read" on public.pl_members;
create policy "members read" on public.pl_members for select to authenticated
  using (user_id = auth.uid() or public.pl_master_in(org_id) or (public.pl_member(org_id)).id is not null);

-- business name and settings: changed one business at a time (trial/licence still only via pl_set_trial)
drop policy if exists "orgs admin update" on public.pl_orgs;
create policy "orgs admin update" on public.pl_orgs for update to authenticated
  using (public.pl_master_in(id) or (public.pl_is_org_admin(id) and not public.pl_org_locked(id)))
  with check (public.pl_master_in(id) or (public.pl_is_org_admin(id) and not public.pl_org_locked(id)));

revoke execute on function public.pl_req_org(), public.pl_master_in(text) from public, anon;
grant execute on function public.pl_req_org(), public.pl_master_in(text) to authenticated;
