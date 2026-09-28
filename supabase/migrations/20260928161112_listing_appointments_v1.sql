begin;

-- One current appointment per chosen listing. The legacy listings.when_text
-- remains the customer's broad preference and is intentionally unchanged.
create table if not exists public.listing_appointments (
  id bigint generated always as identity primary key,
  listing_id bigint not null unique references public.listings(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  proposed_at timestamptz not null,
  proposed_by uuid not null references public.profiles(id) on delete cascade,
  status text not null,
  revision bigint not null default 1,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint listing_appointments_distinct_parties check (customer_id <> professional_id),
  constraint listing_appointments_proposer_is_party check (proposed_by in (customer_id, professional_id)),
  constraint listing_appointments_status_check check (status in ('awaiting_expert','awaiting_customer','confirmed')),
  constraint listing_appointments_revision_check check (revision > 0),
  constraint listing_appointments_confirmation_check check (
    (status = 'confirmed' and confirmed_at is not null)
    or (status <> 'confirmed' and confirmed_at is null)
  )
);

create index if not exists listing_appointments_customer_id_idx
  on public.listing_appointments(customer_id);
create index if not exists listing_appointments_professional_id_idx
  on public.listing_appointments(professional_id);

alter table public.listing_appointments enable row level security;

revoke all on table public.listing_appointments from public, anon, authenticated;
grant select on table public.listing_appointments to authenticated;

drop policy if exists "appointment parties can read" on public.listing_appointments;
create policy "appointment parties can read"
on public.listing_appointments
for select
to authenticated
using (
  (select auth.uid()) is not null
  and (select auth.uid()) in (customer_id, professional_id)
);

create or replace function public.propose_listing_appointment(
  p_listing_id bigint,
  p_proposed_at timestamptz,
  p_expected_revision bigint
)
returns public.listing_appointments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_current public.listing_appointments%rowtype;
  v_result public.listing_appointments%rowtype;
  v_status text;
  v_recipient uuid;
  v_body text;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;
  if p_proposed_at is null then
    raise exception 'Geçerli bir tarih ve saat seçmelisin';
  end if;
  if p_proposed_at <= now() then
    raise exception 'Randevu zamanı gelecekte olmalı';
  end if;
  if p_proposed_at > now() + interval '90 days' then
    raise exception 'Randevu en fazla 90 gün sonrası için önerilebilir';
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id
  for update;

  if v_listing.id is null or v_listing.status <> 'chosen'
     or v_listing.chosen_quote is null then
    raise exception 'Randevu için önce uzman seçilmiş olmalı' using errcode = '42501';
  end if;

  select * into v_quote
  from public.quotes
  where id = v_listing.chosen_quote and listing_id = v_listing.id;

  if v_quote.id is null or v_uid not in (v_listing.owner, v_quote.pro) then
    raise exception 'Bu randevu için yetkin yok' using errcode = '42501';
  end if;

  select * into v_current
  from public.listing_appointments
  where listing_id = p_listing_id
  for update;

  v_status := case when v_uid = v_listing.owner
    then 'awaiting_expert' else 'awaiting_customer' end;

  -- Safe retry: the same proposal does not increment the revision or notify twice.
  if v_current.id is not null
     and v_current.status = v_status
     and v_current.proposed_by = v_uid
     and v_current.proposed_at = p_proposed_at then
    return v_current;
  end if;

  if v_current.id is null then
    if v_uid <> v_listing.owner then
      raise exception 'İlk randevu önerisini müşteri oluşturmalı' using errcode = '42501';
    end if;
    if coalesce(p_expected_revision, -1) <> 0 then
      raise exception 'Randevu bilgisi değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
    end if;

    insert into public.listing_appointments(
      listing_id, customer_id, professional_id, proposed_at,
      proposed_by, status, revision
    ) values (
      p_listing_id, v_listing.owner, v_quote.pro, p_proposed_at,
      v_uid, 'awaiting_expert', 1
    ) returning * into v_result;
    v_recipient := v_quote.pro;
    v_body := 'Müşteri ' || to_char(p_proposed_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI') || ' için randevu önerdi.';
  else
    if v_current.status = 'confirmed' then
      raise exception 'Kesinleşmiş randevu bu ekrandan değiştirilemez';
    end if;
    if v_current.revision <> p_expected_revision then
      raise exception 'Randevu bilgisi değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
    end if;
    if v_uid = v_listing.owner and v_current.status <> 'awaiting_customer' then
      raise exception 'Uzmanın yanıtı bekleniyor';
    end if;
    if v_uid = v_quote.pro and v_current.status <> 'awaiting_expert' then
      raise exception 'Müşterinin yanıtı bekleniyor';
    end if;

    update public.listing_appointments
    set proposed_at = p_proposed_at,
        proposed_by = v_uid,
        status = v_status,
        revision = revision + 1,
        confirmed_at = null,
        updated_at = now()
    where id = v_current.id
    returning * into v_result;

    if v_uid = v_listing.owner then
      v_recipient := v_quote.pro;
      v_body := 'Müşteri ' || to_char(p_proposed_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI') || ' için yeni bir zaman önerdi.';
    else
      v_recipient := v_listing.owner;
      v_body := 'Uzman ' || to_char(p_proposed_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI') || ' için alternatif bir zaman önerdi.';
    end if;
  end if;

  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(v_recipient,'appointment_proposed','Yeni randevu önerisi',v_body,p_listing_id,v_uid);

  return v_result;
end;
$$;

create or replace function public.accept_listing_appointment(
  p_listing_id bigint,
  p_expected_revision bigint
)
returns public.listing_appointments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_current public.listing_appointments%rowtype;
  v_result public.listing_appointments%rowtype;
  v_recipient uuid;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id
  for update;

  if v_listing.id is null or v_listing.status <> 'chosen'
     or v_listing.chosen_quote is null then
    raise exception 'Aktif randevu bulunamadı' using errcode = '42501';
  end if;

  select * into v_quote
  from public.quotes
  where id = v_listing.chosen_quote and listing_id = v_listing.id;

  if v_quote.id is null or v_uid not in (v_listing.owner, v_quote.pro) then
    raise exception 'Bu randevu için yetkin yok' using errcode = '42501';
  end if;

  select * into v_current
  from public.listing_appointments
  where listing_id = p_listing_id
  for update;

  if v_current.id is null
     or v_current.customer_id <> v_listing.owner
     or v_current.professional_id <> v_quote.pro then
    raise exception 'Aktif randevu bulunamadı';
  end if;

  -- Safe retry after a successful accept. Only the party who accepted the
  -- current proposal can use this idempotent path.
  if v_current.status = 'confirmed'
     and v_current.revision = p_expected_revision + 1
     and v_current.proposed_by <> v_uid then
    return v_current;
  end if;

  if v_current.revision <> p_expected_revision then
    raise exception 'Randevu bilgisi değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
  end if;
  if v_current.proposed_at <= now() then
    raise exception 'Geçmiş bir randevu kabul edilemez';
  end if;
  if v_current.status = 'awaiting_expert' and v_uid <> v_quote.pro then
    raise exception 'Bu öneriyi yalnız seçilen uzman kabul edebilir' using errcode = '42501';
  end if;
  if v_current.status = 'awaiting_customer' and v_uid <> v_listing.owner then
    raise exception 'Bu öneriyi yalnız ilan sahibi kabul edebilir' using errcode = '42501';
  end if;
  if v_current.status not in ('awaiting_expert','awaiting_customer') then
    raise exception 'Randevu kabul edilmeye uygun değil';
  end if;

  update public.listing_appointments
  set status = 'confirmed',
      revision = revision + 1,
      confirmed_at = now(),
      updated_at = now()
  where id = v_current.id
  returning * into v_result;

  v_recipient := case when v_uid = v_listing.owner then v_quote.pro else v_listing.owner end;
  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(
    v_recipient,
    'appointment_confirmed',
    'Randevu kesinleşti',
    to_char(v_result.proposed_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'),
    p_listing_id,
    v_uid
  );

  return v_result;
end;
$$;

revoke all on function public.propose_listing_appointment(bigint,timestamptz,bigint) from public, anon;
revoke all on function public.accept_listing_appointment(bigint,bigint) from public, anon;
grant execute on function public.propose_listing_appointment(bigint,timestamptz,bigint) to authenticated;
grant execute on function public.accept_listing_appointment(bigint,bigint) to authenticated;

notify pgrst, 'reload schema';

commit;
