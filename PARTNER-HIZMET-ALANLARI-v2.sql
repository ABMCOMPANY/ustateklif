-- Partner paneli yalnızca izin verilen hizmet kategorilerindeki işleri gösterir.
-- NULL service_categories eski partnerler için tüm hizmetler anlamına gelir.

create or replace function public.my_partner_jobs()
returns table (
  listing_id bigint, category text, problems text[], city text, district text,
  neighborhood text, when_text text, status text, external_order_ref text,
  created_at timestamptz, chosen_price integer, discount_amount numeric
)
language sql security definer set search_path = public
as $$
  with mine as (
    select p.id, p.service_categories
    from public.partner_members m
    join public.partners p on p.id=m.partner_id
    where m.user_id=auth.uid() and m.status='active' and p.status='active'
    order by case m.role when 'owner' then 1 when 'manager' then 2 else 3 end, p.name
    limit 1
  )
  select l.id,l.category,l.problems,l.city,l.district,l.neighborhood,l.when_text,l.status,
         l.external_order_ref,l.created_at,q.price,coalesce(pc.discount_amount,0)
  from public.listings l
  join mine m on m.id=l.partner_id
             and (m.service_categories is null or l.category=any(m.service_categories))
  left join public.quotes q on q.id=l.chosen_quote
  left join public.listing_payment_choices pc on pc.listing_id=l.id
  order by l.created_at desc
  limit 100;
$$;

create or replace function public.my_partner_dashboard()
returns table (
  partner_id uuid, partner_name text, listings bigint, open_listings bigint,
  chosen bigint, done bigint, gross_volume numeric, discount_total numeric,
  commission_estimate numeric, partner_promo_contribution numeric
)
language sql security definer set search_path = public
as $$
  with mine as (
    select p.id,p.name,p.service_categories,p.commission_percent,p.promo_share_percent
    from public.partner_members m
    join public.partners p on p.id=m.partner_id
    where m.user_id=auth.uid() and m.status='active' and p.status='active'
    order by case m.role when 'owner' then 1 when 'manager' then 2 else 3 end, p.name
    limit 1
  )
  select m.id,m.name,
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
    and (m.service_categories is null or l.category=any(m.service_categories))
  left join public.quotes q on q.id=l.chosen_quote
  left join public.listing_payment_choices pc on pc.listing_id=l.id
  group by m.id,m.name,m.commission_percent,m.promo_share_percent;
$$;

-- İleride API üzerinden partner işi oluşturulurken veya kategori değiştirilirken
-- kategori kapsamı atlanamasın. Eski işlerin diğer alanlardaki güncellemeleri etkilenmez.
create or replace function public.check_partner_listing_category()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare allowed text[];
begin
  if new.partner_id is null then return new; end if;
  select p.service_categories into allowed from public.partners p where p.id=new.partner_id;
  if allowed is not null and not (new.category=any(allowed)) then
    raise exception 'Partner bu hizmet kategorisinde çalışmıyor';
  end if;
  return new;
end;
$$;

revoke all on function public.check_partner_listing_category() from public, anon, authenticated;

create trigger listings_partner_category_guard
before insert or update of partner_id, category on public.listings
for each row execute function public.check_partner_listing_category();
