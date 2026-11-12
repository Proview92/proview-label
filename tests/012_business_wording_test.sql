-- Local test of supabase/migrations/012_business_wording.sql (run 12 Nov 2026 on a local PostgreSQL 16, not on live): a minimal
-- pl_orgs / pl_records stub, the guard from 011, every case run under 011 and then under 012, compared; all rolled back.
-- Run from tests/ with: awk '/^create or replace function public.pl_sites_guard/,/^create trigger pl_sites_guard/' ../supabase/migrations/011_locations_link.sql > g011.sql; psql -f 012_business_wording_test.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end $$;
create table public.pl_orgs (id text primary key, name text, created_at timestamptz default now());
create table public.pl_records (id text primary key, org_id text, site_id text, kind text, data jsonb default '{}', deleted boolean default false);
grant all on public.pl_orgs, public.pl_records to authenticated;
\i g011.sql
create temp table res (step text, which text, outcome text);
grant all on res to authenticated;
-- old org (not created now) with one site; a run of every case, under a given guard version
create or replace function pg_temp.cases(v text) returns void language plpgsql as $f$
declare e text;
begin
  delete from public.pl_records; delete from public.pl_orgs;
  insert into public.pl_orgs values ('o_old','Old', now() - interval '1 day');
  set local session_replication_role = replica; insert into public.pl_records(id,org_id,site_id,kind) values ('s1','o_old','s1','sites'); set local session_replication_role = origin;
  execute 'set local role authenticated';
  begin insert into public.pl_records(id,org_id,site_id,kind) values ('s2','o_old','s2','sites'); insert into res values ('add',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('add',v,sqlstate||' '||e); end;
  begin update public.pl_records set org_id='o_x' where id='s1'; insert into res values ('move',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('move',v,sqlstate||' '||e); end;
  begin update public.pl_records set deleted=true where id='s1'; insert into res values ('delete',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('delete',v,sqlstate||' '||e); end;
  begin update public.pl_records set data='{"name":"Renamed"}' where id='s1'; insert into res values ('rename',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('rename',v,sqlstate||' '||e); end;
  begin insert into public.pl_records(id,org_id,kind) values ('p1','o_old','products'); insert into res values ('product',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('product',v,sqlstate||' '||e); end;
  execute 'reset role';
  insert into public.pl_orgs values ('o_new','New', now());
  execute 'set local role authenticated';
  begin insert into public.pl_records(id,org_id,site_id,kind) values ('n1','o_new','n1','sites'); insert into res values ('first site of new org',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('first site of new org',v,sqlstate||' '||e); end;
  execute 'reset role';
  perform set_config('pl.hub_move','1',true);
  begin update public.pl_records set org_id='o_new' where id='s1'; insert into res values ('hub move',v,'allowed'); exception when others then get stacked diagnostics e = message_text; insert into res values ('hub move',v,sqlstate||' '||e); end;
  perform set_config('pl.hub_move','',true);
end $f$;
select pg_temp.cases('011');
\i ../supabase/migrations/012_business_wording.sql
select pg_temp.cases('012');
select a.step, a.outcome as "011", b.outcome as "012",
  case when (a.outcome='allowed') = (b.outcome='allowed') and split_part(a.outcome,' ',1)=split_part(b.outcome,' ',1) then 'same' else 'DIFFERENT' end as behaviour
  from res a join res b on a.step=b.step and a.which='011' and b.which='012' order by a.step;
rollback;
