begin;

alter table public.partners
  add column if not exists commission_percent numeric(5,2) not null default 15
    check (commission_percent >= 0 and commission_percent <= 50),
  add column if not exists promo_share_percent numeric(5,2) not null default 0
    check (promo_share_percent >= 0 and promo_share_percent <= 100);

create or replace function public.admin_set_partner_terms(
  p_partner_id uuid,
  p_commission_percent numeric,
  p_promo_share_percent numeric
)
returns public.partners
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.partners%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Yetkisiz';
  end if;
  if p_commission_percent < 0 or p_commission_percent > 50 then
    raise exception 'Komisyon oranı geçersiz';
  end if;
  if p_promo_share_percent < 0 or p_promo_share_percent > 100 then
    raise exception 'Promosyon katkı oranı geçersiz';
  end if;

  update public.partners
  set commission_percent=p_commission_percent,
      promo_share_percent=p_promo_share_percent
  where id=p_partner_id
  returning * into v;

  if v.id is null then raise exception 'Partner bulunamadı'; end if;
  return v;
end;
$$;

revoke all on function public.admin_set_partner_terms(uuid,numeric,numeric) from public, anon;
grant execute on function public.admin_set_partner_terms(uuid,numeric,numeric) to authenticated;

create or replace function public.admin_partner_stats()
returns table(
  partner_id uuid,
  partner_name text,
  listings bigint,
  chosen bigint,
  done bigint,
  gross_volume numeric,
  discount_total numeric,
  platform_commission_estimate numeric,
  partner_promo_contribution_estimate numeric
)
language sql
security definer
set search_path=public
as $$
  select
    p.id,
    p.name,
    count(l.id)::bigint,
    count(*) filter (where l.status in ('chosen','done'))::bigint,
    count(*) filter (where l.status='done')::bigint,
    coalesce(sum(case when l.status in ('chosen','done') then q.price else 0 end),0)::numeric,
    coalesce(sum(case when l.status in ('chosen','done') then coalesce(pc.discount_amount,0) else 0 end),0)::numeric,
    coalesce(sum(case when l.status in ('chosen','done')
      then greatest((q.price-coalesce(pc.discount_amount,0)),0) * p.commission_percent/100.0
      else 0 end),0)::numeric,
    coalesce(sum(case when l.status in ('chosen','done')
      then coalesce(pc.discount_amount,0) * p.promo_share_percent/100.0
      else 0 end),0)::numeric
  from public.partners p
  left join public.listings l on l.partner_id=p.id
  left join public.quotes q on q.id=l.chosen_quote
  left join public.listing_payment_choices pc on pc.listing_id=l.id
  where public.is_admin()
  group by p.id,p.name,p.commission_percent,p.promo_share_percent
  order by p.name;
$$;

revoke all on function public.admin_partner_stats() from public, anon;
grant execute on function public.admin_partner_stats() to authenticated;

commit;
