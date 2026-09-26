begin;

-- The client may read choices, but payment/promo selections are now written only through RPC.
revoke insert, update, delete on public.listing_payment_choices from authenticated;

-- One-time redemption backfill for selections already made during testing.
insert into public.promo_redemptions(promotion_id,user_id,listing_id,quote_id,discount_amount,created_at)
select c.promotion_id,c.customer_id,c.listing_id,c.quote_id,c.discount_amount,c.created_at
from public.listing_payment_choices c
where c.promotion_id is not null
  and not exists (
    select 1 from public.promo_redemptions r
    where r.promotion_id=c.promotion_id and r.user_id=c.customer_id and r.listing_id=c.listing_id
  );

update public.promotions
set new_users_only=true, per_user_limit=1
where code='ILKIS100';

create or replace function public.validate_promotion(
  p_code text,
  p_listing_id bigint,
  p_quote_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_p public.promotions%rowtype;
  v_l public.listings%rowtype;
  v_q public.quotes%rowtype;
  v_used integer;
  v_total integer;
  v_prior integer;
  v_discount numeric(12,2);
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  select * into v_l from public.listings
  where id=p_listing_id and owner=v_uid and status='open';
  if v_l.id is null then raise exception 'İlan uygun değil'; end if;

  select * into v_q from public.quotes
  where id=p_quote_id and listing_id=p_listing_id;
  if v_q.id is null then raise exception 'Teklif bulunamadı'; end if;

  select * into v_p from public.promotions
  where upper(code)=upper(trim(p_code))
  for update;
  if v_p.id is null then raise exception 'Promosyon kodu geçerli değil'; end if;
  if v_p.status<>'active' or v_p.starts_at>now() or (v_p.ends_at is not null and v_p.ends_at<now()) then
    raise exception 'Kampanya aktif değil';
  end if;
  if v_q.price < v_p.min_amount then
    raise exception 'Minimum hizmet tutarı % olmalı', v_p.min_amount;
  end if;
  if cardinality(v_p.categories)>0 and not (v_l.category=any(v_p.categories)) then
    raise exception 'Kampanya bu hizmette geçerli değil';
  end if;
  if cardinality(v_p.cities)>0 and not (v_l.city=any(v_p.cities)) then
    raise exception 'Kampanya bu şehirde geçerli değil';
  end if;
  if v_p.partner_id is not null and v_l.partner_id is distinct from v_p.partner_id then
    raise exception 'Kampanya bu partner işi için geçerli değil';
  end if;

  select count(*) into v_used from public.promo_redemptions
  where promotion_id=v_p.id and user_id=v_uid;
  if v_p.per_user_limit is not null and v_used>=v_p.per_user_limit then
    raise exception 'Bu promosyonu daha önce kullandın';
  end if;

  select count(*) into v_total from public.promo_redemptions where promotion_id=v_p.id;
  if v_p.total_limit is not null and v_total>=v_p.total_limit then
    raise exception 'Kampanya kullanım limiti doldu';
  end if;

  if v_p.new_users_only then
    select count(*) into v_prior
    from public.listings
    where owner=v_uid and id<>p_listing_id and status in ('chosen','done');
    if v_prior>0 then raise exception 'Bu kampanya yalnızca ilk iş için geçerli'; end if;
  end if;

  v_discount := case
    when v_p.discount_type='percent' then round((v_q.price * v_p.discount_value / 100.0)::numeric,2)
    else v_p.discount_value
  end;
  if v_p.max_discount is not null then v_discount:=least(v_discount,v_p.max_discount); end if;
  v_discount:=greatest(0,least(v_discount,v_q.price));

  return jsonb_build_object(
    'id',v_p.id,'code',v_p.code,'title',v_p.title,
    'discount',v_discount,'final_amount',v_q.price-v_discount
  );
end;
$$;

revoke all on function public.validate_promotion(text,bigint,bigint) from public, anon;
grant execute on function public.validate_promotion(text,bigint,bigint) to authenticated;

create or replace function public.choose_quote_with_payment(
  p_listing_id bigint,
  p_quote_id bigint,
  p_method text,
  p_deposit_percent smallint default null,
  p_promotion_id uuid default null
)
returns public.listings
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  result public.listings;
  v_l public.listings%rowtype;
  v_q public.quotes%rowtype;
  v_p public.promotions%rowtype;
  v_used integer;
  v_total integer;
  v_prior integer;
  v_discount numeric(12,2):=0;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  select * into v_l from public.listings
  where id=p_listing_id and owner=v_uid and status='open'
  for update;
  if v_l.id is null then
    raise exception 'İlan açık değil veya sana ait değil';
  end if;

  select * into v_q from public.quotes
  where id=p_quote_id and listing_id=p_listing_id;
  if v_q.id is null or v_q.pro=v_l.owner or public.is_blocked(v_uid,v_q.pro) then
    raise exception 'Bu teklif seçilemez';
  end if;

  if p_method is null or not (p_method=any(v_q.payment_methods)) then
    raise exception 'Ödeme yöntemi uzman tarafından kabul edilmiyor';
  end if;
  if p_method='deposit_cash' then
    if p_deposit_percent is null or p_deposit_percent is distinct from v_q.deposit_percent then
      raise exception 'Ön ödeme oranı geçersiz';
    end if;
  else
    p_deposit_percent:=null;
  end if;

  if p_promotion_id is not null then
    select * into v_p from public.promotions where id=p_promotion_id for update;
    if v_p.id is null or v_p.status<>'active' or v_p.starts_at>now()
       or (v_p.ends_at is not null and v_p.ends_at<now()) then
      raise exception 'Promosyon geçerli değil';
    end if;
    if v_q.price < v_p.min_amount then raise exception 'Promosyon için tutar yetersiz'; end if;
    if cardinality(v_p.categories)>0 and not (v_l.category=any(v_p.categories)) then raise exception 'Promosyon bu hizmette geçerli değil'; end if;
    if cardinality(v_p.cities)>0 and not (v_l.city=any(v_p.cities)) then raise exception 'Promosyon bu şehirde geçerli değil'; end if;
    if v_p.partner_id is not null and v_l.partner_id is distinct from v_p.partner_id then raise exception 'Promosyon bu partner işi için geçerli değil'; end if;

    select count(*) into v_used from public.promo_redemptions where promotion_id=v_p.id and user_id=v_uid;
    if v_p.per_user_limit is not null and v_used>=v_p.per_user_limit then raise exception 'Bu promosyonu daha önce kullandın'; end if;
    select count(*) into v_total from public.promo_redemptions where promotion_id=v_p.id;
    if v_p.total_limit is not null and v_total>=v_p.total_limit then raise exception 'Kampanya kullanım limiti doldu'; end if;
    if v_p.new_users_only then
      select count(*) into v_prior from public.listings where owner=v_uid and id<>p_listing_id and status in ('chosen','done');
      if v_prior>0 then raise exception 'Bu kampanya yalnızca ilk iş için geçerli'; end if;
    end if;

    v_discount:=case when v_p.discount_type='percent'
      then round((v_q.price*v_p.discount_value/100.0)::numeric,2)
      else v_p.discount_value end;
    if v_p.max_discount is not null then v_discount:=least(v_discount,v_p.max_discount); end if;
    v_discount:=greatest(0,least(v_discount,v_q.price));
  end if;

  update public.listings
  set status='chosen',chosen_quote=p_quote_id
  where id=p_listing_id
  returning * into result;

  insert into public.listing_payment_choices(
    listing_id,quote_id,customer_id,method,deposit_percent,promotion_id,discount_amount
  ) values (
    p_listing_id,p_quote_id,v_uid,p_method,p_deposit_percent,p_promotion_id,v_discount
  );

  if p_promotion_id is not null then
    insert into public.promo_redemptions(promotion_id,user_id,listing_id,quote_id,discount_amount)
    values(p_promotion_id,v_uid,p_listing_id,p_quote_id,v_discount);
  end if;

  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(v_q.pro,'chosen','Teklifin seçildi','Müşteri teklifini seçti. Artık mesajlaşabilirsiniz.',p_listing_id,v_uid);

  return result;
end;
$$;

revoke all on function public.choose_quote_with_payment(bigint,bigint,text,smallint,uuid) from public, anon;
grant execute on function public.choose_quote_with_payment(bigint,bigint,text,smallint,uuid) to authenticated;

commit;
