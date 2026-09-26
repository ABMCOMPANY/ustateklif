
begin;

drop view if exists public.pro_stats;
drop view if exists public.quote_counts;

create table public.pro_stats (
  pro_id uuid primary key references public.profiles(id) on delete cascade,
  jobs integer not null default 0 check (jobs >= 0),
  rating numeric(3,1)
);

create table public.quote_counts (
  listing_id bigint primary key references public.listings(id) on delete cascade,
  n integer not null default 0 check (n >= 0)
);

alter table public.pro_stats enable row level security;
alter table public.quote_counts enable row level security;

grant select on public.pro_stats to anon, authenticated;
grant select on public.quote_counts to authenticated;
revoke insert, update, delete on public.pro_stats from anon, authenticated;
revoke insert, update, delete on public.quote_counts from anon, authenticated;

create policy pro_stats_public_read
on public.pro_stats for select
to anon, authenticated
using (true);

create policy quote_counts_auth_read
on public.quote_counts for select
to authenticated
using (true);

create or replace function public.refresh_pro_stats_for(p_pro uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_pro is null then return; end if;
  insert into public.pro_stats(pro_id,jobs,rating)
  select p_pro,
         count(*) filter (where l.status='done')::integer,
         round(avg(l.rating) filter (where l.status='done'),1)
  from public.listings l
  join public.quotes q on q.id=l.chosen_quote
  where q.pro=p_pro
  on conflict (pro_id) do update
  set jobs=excluded.jobs, rating=excluded.rating;
end;
$$;

create or replace function public.sync_pro_stats_from_listing()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_old_pro uuid;
  v_new_pro uuid;
begin
  if tg_op <> 'INSERT' and old.chosen_quote is not null then
    select pro into v_old_pro from public.quotes where id=old.chosen_quote;
  end if;
  if tg_op <> 'DELETE' and new.chosen_quote is not null then
    select pro into v_new_pro from public.quotes where id=new.chosen_quote;
  end if;

  perform public.refresh_pro_stats_for(v_old_pro);
  if v_new_pro is distinct from v_old_pro then
    perform public.refresh_pro_stats_for(v_new_pro);
  end if;
  return coalesce(new,old);
end;
$$;

drop trigger if exists trg_sync_pro_stats_listing on public.listings;
create trigger trg_sync_pro_stats_listing
after insert or update of status,rating,chosen_quote or delete
on public.listings
for each row execute function public.sync_pro_stats_from_listing();

create or replace function public.sync_quote_count()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_listing_id bigint;
begin
  v_listing_id:=coalesce(new.listing_id,old.listing_id);
  insert into public.quote_counts(listing_id,n)
  select v_listing_id, count(*)::integer
  from public.quotes
  where listing_id=v_listing_id
  on conflict (listing_id) do update set n=excluded.n;
  return coalesce(new,old);
end;
$$;

drop trigger if exists trg_sync_quote_count on public.quotes;
create trigger trg_sync_quote_count
after insert or delete
on public.quotes
for each row execute function public.sync_quote_count();

insert into public.pro_stats(pro_id,jobs,rating)
select q.pro,
       count(*) filter (where l.status='done')::integer,
       round(avg(l.rating) filter (where l.status='done'),1)
from public.quotes q
join public.listings l on l.chosen_quote=q.id
group by q.pro
on conflict (pro_id) do update set jobs=excluded.jobs,rating=excluded.rating;

insert into public.quote_counts(listing_id,n)
select l.id,count(q.id)::integer
from public.listings l
left join public.quotes q on q.listing_id=l.id
group by l.id
on conflict (listing_id) do update set n=excluded.n;

revoke all on function public.refresh_pro_stats_for(uuid) from public, anon, authenticated;
revoke all on function public.sync_pro_stats_from_listing() from public, anon, authenticated;
revoke all on function public.sync_quote_count() from public, anon, authenticated;

revoke execute on function public.is_party(bigint) from public, anon;
grant execute on function public.is_party(bigint) to authenticated;

commit;
