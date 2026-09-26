begin;

create table if not exists public.partner_members (
  partner_id uuid not null references public.partners(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'viewer' check (role in ('owner','manager','viewer')),
  status text not null default 'active' check (status in ('active','disabled')),
  created_at timestamptz not null default now(),
  primary key(partner_id,user_id)
);

alter table public.partner_members enable row level security;
grant select on public.partner_members to authenticated;
revoke insert,update,delete on public.partner_members from authenticated;
revoke all on public.partner_members from anon;

drop policy if exists partner_members_read_own on public.partner_members;
create policy partner_members_read_own
on public.partner_members for select to authenticated
using (user_id=(select auth.uid()) or public.is_admin());

create or replace function public.my_partner_context()
returns table(
  partner_id uuid,
  partner_name text,
  partner_slug text,
  member_role text,
  commission_percent numeric,
  promo_share_percent numeric
)
language sql
security definer
set search_path=public
as $$
  select p.id,p.name,p.slug,m.role,p.commission_percent,p.promo_share_percent
  from public.partner_members m
  join public.partners p on p.id=m.partner_id
  where m.user_id=auth.uid()
    and m.status='active'
    and p.status='active'
  order by case m.role when 'owner' then 1 when 'manager' then 2 else 3 end, p.name
  limit 1;
$$;

revoke all on function public.my_partner_context() from public, anon;
grant execute on function public.my_partner_context() to authenticated;

create or replace function public.my_partner_dashboard()
returns table(
  partner_id uuid,
  partner_name text,
  listings bigint,
  open_listings bigint,
  chosen bigint,
  done bigint,
  gross_volume numeric,
  discount_total numeric,
  commission_estimate numeric,
  partner_promo_contribution numeric
)
language sql
security definer
set search_path=public
as $$
  with mine as (
    select p.id,p.name,p.commission_percent,p.promo_share_percent
    from public.partner_members m
    join public.partners p on p.id=m.partner_id
    where m.user_id=auth.uid() and m.status='active' and p.status='active'
    order by case m.role when 'owner' then 1 when 'manager' then 2 else 3 end
    limit 1
  )
  select
    m.id,
    m.name,
    count(l.id)::bigint,
    count(*) filter (where l.status='open')::bigint,
    count(*) filter (where l.status in ('chosen','done'))::bigint,
    count(*) filter (where l.status='done')::bigint,
    coalesce(sum(case when l.status in ('chosen','done') then q.price else 0 end),0)::numeric,
    coalesce(sum(case when l.status in ('chosen','done') then coalesce(pc.discount_amount,0) else 0 end),0)::numeric,
    coalesce(sum(case when l.status in ('chosen','done')
      then greatest(q.price-coalesce(pc.discount_amount,0),0)*m.commission_percent/100.0 else 0 end),0)::numeric,
    coalesce(sum(case when l.status in ('chosen','done')
      then coalesce(pc.discount_amount,0)*m.promo_share_percent/100.0 else 0 end),0)::numeric
  from mine m
  left join public.listings l on l.partner_id=m.id
  left join public.quotes q on q.id=l.chosen_quote
  left join public.listing_payment_choices pc on pc.listing_id=l.id
  group by m.id,m.name,m.commission_percent,m.promo_share_percent;
$$;

revoke all on function public.my_partner_dashboard() from public, anon;
grant execute on function public.my_partner_dashboard() to authenticated;

create or replace function public.my_partner_jobs()
returns table(
  listing_id bigint,
  category text,
  problems text[],
  city text,
  district text,
  neighborhood text,
  when_text text,
  status text,
  external_order_ref text,
  created_at timestamptz,
  chosen_price integer,
  discount_amount numeric
)
language sql
security definer
set search_path=public
as $$
  with mine as (
    select m.partner_id
    from public.partner_members m
    join public.partners p on p.id=m.partner_id
    where m.user_id=auth.uid() and m.status='active' and p.status='active'
    limit 1
  )
  select l.id,l.category,l.problems,l.city,l.district,l.neighborhood,l.when_text,l.status,
         l.external_order_ref,l.created_at,q.price,coalesce(pc.discount_amount,0)
  from public.listings l
  join mine m on m.partner_id=l.partner_id
  left join public.quotes q on q.id=l.chosen_quote
  left join public.listing_payment_choices pc on pc.listing_id=l.id
  order by l.created_at desc
  limit 100;
$$;

revoke all on function public.my_partner_jobs() from public, anon;
grant execute on function public.my_partner_jobs() to authenticated;

-- Test access: attach the existing admin account to the demo partner as owner.
insert into public.partner_members(partner_id,user_id,role,status)
select p.id,a.user_id,'owner','active'
from public.partners p
cross join public.admin_users a
where p.slug='tamisim-demo'
on conflict(partner_id,user_id) do update set role='owner',status='active';

commit;
