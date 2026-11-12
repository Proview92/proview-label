-- 012: "business", not "location", in the refusals people see (owner, 12 Nov 2026: the licence portal now says
-- Businesses throughout: "New business", "Link with another business…"). Only the wording of pl_sites_guard (migration
-- 011) changes; what it allows and refuses is exactly the same. Apply after 011.
create or replace function public.pl_sites_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('pl.hub_move', true), '') = '1' and current_user not in ('anon', 'authenticated') then
    return new;                                                                        -- hub link / unlink
  end if;
  if tg_op = 'INSERT' then
    if new.kind <> 'sites' then return new; end if;
    -- an upsert of a location that already exists is an edit (the UPDATE trigger checks it)
    if exists (select 1 from public.pl_records r where r.id = new.id) then return new; end if;
    -- the first location of a business created in this same transaction (New business in the portal, self sign-up)
    if exists (select 1 from public.pl_orgs o where o.id = new.org_id and o.created_at = now())
       and not exists (select 1 from public.pl_records r where r.org_id = new.org_id and r.kind = 'sites') then
      return new;
    end if;
    raise exception 'Businesses are set up by Proview in the licence portal, so a location can''t be added here.' using errcode = '42501';
  end if;
  -- UPDATE
  if old.kind = 'sites' or new.kind = 'sites' then
    if new.kind is distinct from old.kind or new.org_id is distinct from old.org_id or new.site_id is distinct from old.site_id then
      raise exception 'A location can''t be moved to another business here. Proview links businesses in the licence portal.' using errcode = '42501';
    end if;
    if new.deleted and not old.deleted then
      raise exception 'Locations can''t be deleted here. Proview links and unlinks businesses in the licence portal.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.pl_sites_guard() from public, anon, authenticated;
