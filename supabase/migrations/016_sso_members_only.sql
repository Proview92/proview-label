-- 016 (owner, 19 Nov 2026: "why can babnewington see labels"). sso_entitled said yes to ANY email that was not yet a
-- member of a Label business (left from the old "Set up your business" self sign-up, 007). So the Proview dashboard
-- listed Proview Label as an active app for everybody, and "Open" made them an empty Label login.
-- Businesses are now added by Proview in the licence portal only, so a Proview account may sign in to Label only as:
--   the Label master, or a member of a business that isn't suspended (even with no licence, so the owner reaches the
--   licence message). Everyone else: "No Proview Label account for this email." (the dashboard shows Label inactive).
-- Same shape and on-hold rule as 015 (one password). Safe to run more than once.
create or replace function public.sso_entitled(p_email text) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; ban timestamptz; em text := lower(trim(p_email));
begin
  select id, banned_until into uid, ban from auth.users
   where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
  if ban > now() then
    return jsonb_build_object('ok', false, 'reason', 'This Label login is on hold. Contact Proview.');
  end if;
  if exists (select 1 from public.pl_masters where email = em)
     or exists (select 1 from public.pl_members m join public.pl_orgs o on o.id = m.org_id where m.email = em and not o.suspended) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Label account for this email.');
end $$;
revoke execute on function public.sso_entitled(text) from public, anon, authenticated;
grant execute on function public.sso_entitled(text) to service_role;
