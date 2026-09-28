begin;

-- Sprint 5A: choosing a professional and choosing a payment method are
-- separate, transaction-safe operations. The legacy combined RPC remains
-- available for backward compatibility with already deployed clients.

create or replace function public.select_quote(
  p_listing_id bigint,
  p_quote_id bigint
)
returns public.listings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_error text;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id and owner = v_uid
  for update;

  if v_listing.id is null then
    raise exception 'İlan sana ait değil' using errcode = '42501';
  end if;

  -- Idempotent retry: a duplicate tap/request returns the already completed
  -- selection without creating a second notification.
  if v_listing.status = 'chosen' and v_listing.chosen_quote = p_quote_id then
    return v_listing;
  end if;

  if v_listing.status <> 'open' or v_listing.chosen_quote is not null then
    raise exception 'Bu ilan için uzman zaten seçilmiş';
  end if;

  select * into v_quote
  from public.quotes
  where id = p_quote_id and listing_id = p_listing_id;

  if v_quote.id is null or v_quote.pro = v_listing.owner
     or public.is_blocked(v_uid, v_quote.pro) then
    raise exception 'Bu teklif seçilemez' using errcode = '42501';
  end if;

  -- Keep Sprint 1 authorization and verification revocation serialized with
  -- selection. Do not duplicate its business rules here.
  perform 1 from public.profiles where id = v_quote.pro for share;
  perform 1 from public.professional_verifications
    where user_id = v_quote.pro for share;
  v_error := expert_security.quote_error(v_quote.pro, p_listing_id);
  if v_error is not null then
    raise exception '%', v_error using errcode = '42501';
  end if;

  update public.listings
  set status = 'chosen', chosen_quote = p_quote_id
  where id = p_listing_id
  returning * into v_listing;

  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(
    v_quote.pro,
    'chosen',
    'Teklifin seçildi',
    'Müşteri teklifini seçti. Artık mesajlaşabilirsiniz.',
    p_listing_id,
    v_uid
  );

  return v_listing;
end;
$$;

create or replace function public.set_listing_payment_choice(
  p_listing_id bigint,
  p_method text,
  p_deposit_percent smallint default null
)
returns public.listing_payment_choices
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_existing public.listing_payment_choices%rowtype;
  v_result public.listing_payment_choices%rowtype;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id and owner = v_uid and status = 'chosen'
  for update;

  if v_listing.id is null or v_listing.chosen_quote is null then
    raise exception 'Ödeme seçimi için önce uzman seçmelisin' using errcode = '42501';
  end if;

  select * into v_quote
  from public.quotes
  where id = v_listing.chosen_quote and listing_id = v_listing.id;

  if v_quote.id is null then
    raise exception 'Seçili teklif bulunamadı';
  end if;

  if p_method is null or not (p_method = any(v_quote.payment_methods)) then
    raise exception 'Ödeme yöntemi uzman tarafından kabul edilmiyor';
  end if;

  if p_method = 'deposit_cash' then
    if p_deposit_percent is null
       or p_deposit_percent is distinct from v_quote.deposit_percent then
      raise exception 'Ön ödeme oranı geçersiz';
    end if;
  else
    p_deposit_percent := null;
  end if;

  select * into v_existing
  from public.listing_payment_choices
  where listing_id = p_listing_id
  for update;

  if v_existing.listing_id is not null then
    if v_existing.quote_id = v_quote.id
       and v_existing.method = p_method
       and v_existing.deposit_percent is not distinct from p_deposit_percent then
      return v_existing;
    end if;
    raise exception 'Bu ilan için ödeme yöntemi zaten seçilmiş';
  end if;

  insert into public.listing_payment_choices(
    listing_id, quote_id, customer_id, method, deposit_percent,
    promotion_id, discount_amount
  ) values (
    p_listing_id, v_quote.id, v_uid, p_method, p_deposit_percent,
    null, 0
  )
  returning * into v_result;

  return v_result;
end;
$$;

revoke all on function public.select_quote(bigint,bigint) from public, anon;
revoke all on function public.set_listing_payment_choice(bigint,text,smallint) from public, anon;
grant execute on function public.select_quote(bigint,bigint) to authenticated;
grant execute on function public.set_listing_payment_choice(bigint,text,smallint) to authenticated;

notify pgrst, 'reload schema';

commit;
