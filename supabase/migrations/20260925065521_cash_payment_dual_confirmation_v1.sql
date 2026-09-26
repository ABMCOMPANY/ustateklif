begin;

alter table public.listing_payment_choices
  add column if not exists customer_cash_confirmed_at timestamptz,
  add column if not exists pro_cash_confirmed_at timestamptz,
  add column if not exists cash_confirmed_at timestamptz;

create or replace function public.confirm_cash_payment(p_listing_id bigint)
returns public.listing_payment_choices
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v public.listing_payment_choices%rowtype;
  v_pro uuid;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  select c.* into v
  from public.listing_payment_choices c
  where c.listing_id=p_listing_id
  for update;

  if v.listing_id is null then
    raise exception 'Ödeme kaydı bulunamadı';
  end if;

  select q.pro into v_pro
  from public.quotes q
  where q.id=v.quote_id;

  if v.method not in ('cash','deposit_cash') then
    raise exception 'Bu iş nakit ödeme kullanmıyor';
  end if;

  if v_uid=v.customer_id then
    update public.listing_payment_choices
    set customer_cash_confirmed_at=coalesce(customer_cash_confirmed_at,now())
    where listing_id=p_listing_id
    returning * into v;
  elsif v_uid=v_pro then
    update public.listing_payment_choices
    set pro_cash_confirmed_at=coalesce(pro_cash_confirmed_at,now())
    where listing_id=p_listing_id
    returning * into v;
  else
    raise exception 'Bu işleme yetkin yok';
  end if;

  if v.customer_cash_confirmed_at is not null and v.pro_cash_confirmed_at is not null then
    update public.listing_payment_choices
    set cash_confirmed_at=coalesce(cash_confirmed_at,now())
    where listing_id=p_listing_id
    returning * into v;
  end if;

  return v;
end;
$$;

revoke all on function public.confirm_cash_payment(bigint) from public, anon;
grant execute on function public.confirm_cash_payment(bigint) to authenticated;

commit;
