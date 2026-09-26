begin;

create or replace function public.apply_promotion_to_selected_listing(
  p_code text,
  p_listing_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_l public.listings%rowtype;
  v_q public.quotes%rowtype;
  v_pc public.listing_payment_choices%rowtype;
  v_p public.promotions%rowtype;
  v_used integer;
  v_total integer;
  v_prior integer;
  v_discount numeric(12,2);
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  select * into v_l
  from public.listings
  where id=p_listing_id and owner=v_uid and status='chosen'
  for update;
  if v_l.id is null then raise exception 'İlan promosyon için uygun değil'; end if;

  select * into v_q from public.quotes where id=v_l.chosen_quote;
  if v_q.id is null then raise exception 'Seçili teklif bulunamadı'; end if;

  select * into v_pc
  from public.listing_payment_choices
  where listing_id=p_listing_id
  for update;
  if v_pc.listing_id is null then raise exception 'Ödeme kaydı bulunamadı'; end if;
  if v_pc.promotion_id is not null or coalesce(v_pc.discount_amount,0)>0 then
    raise exception 'Bu işe zaten promosyon uygulanmış';
  end if;

  select * into v_p
  from public.promotions
  where upper(code)=upper(trim(p_code))
  for update;
  if v_p.id is null then raise exception 'Promosyon kodu geçerli değil'; end if;
  if v_p.status<>'active' or v_p.starts_at>now() or (v_p.ends_at is not null and v_p.ends_at<now()) then
    raise exception 'Kampanya aktif değil';
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
    select count(*) into v_prior
    from public.listings
    where owner=v_uid and id<>p_listing_id and status in ('chosen','done');
    if v_prior>0 then raise exception 'Bu kampanya yalnızca ilk iş için geçerli'; end if;
  end if;

  v_discount:=case when v_p.discount_type='percent'
    then round((v_q.price*v_p.discount_value/100.0)::numeric,2)
    else v_p.discount_value end;
  if v_p.max_discount is not null then v_discount:=least(v_discount,v_p.max_discount); end if;
  v_discount:=greatest(0,least(v_discount,v_q.price));

  update public.listing_payment_choices
  set promotion_id=v_p.id,
      discount_amount=v_discount
  where listing_id=p_listing_id;

  insert into public.promo_redemptions(promotion_id,user_id,listing_id,quote_id,discount_amount)
  values(v_p.id,v_uid,p_listing_id,v_q.id,v_discount);

  return jsonb_build_object(
    'id',v_p.id,'code',v_p.code,'title',v_p.title,
    'discount',v_discount,'final_amount',v_q.price-v_discount
  );
end;
$$;

revoke all on function public.apply_promotion_to_selected_listing(text,bigint) from public, anon;
grant execute on function public.apply_promotion_to_selected_listing(text,bigint) to authenticated;

commit;
