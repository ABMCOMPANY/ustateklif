begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

-- Sprint 6A-2A. REVIEW ONLY: do not deploy until separately approved.
-- One appointment per listing is retained. Cancellation does NOT cancel the job.
-- Last cancellation metadata is retained when a customer starts a new proposal.
alter table public.listing_appointments
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid,
  add column if not exists cancel_reason text;
alter table public.listing_appointments drop constraint listing_appointments_status_check;
alter table public.listing_appointments add constraint listing_appointments_status_check
  check (status in ('awaiting_expert','awaiting_customer','confirmed','cancelled'));
alter table public.listing_appointments drop constraint if exists listing_appointments_cancel_audit_check;
alter table public.listing_appointments add constraint listing_appointments_cancel_audit_check check (
  ((cancelled_at is null and cancelled_by is null and cancel_reason is null)
   or (cancelled_at is not null and cancelled_by is not null
       and cancelled_by in (customer_id,professional_id)))
  and (status <> 'cancelled' or cancelled_at is not null)
  and (cancel_reason is null or (char_length(cancel_reason) between 1 and 500 and cancel_reason = btrim(cancel_reason)))
);
comment on column public.listing_appointments.cancelled_at is 'Last cancellation, retained on subsequent proposals; not a full event history.';

alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (
  type in ('quote','chosen','message','nearby_job','appointment_proposed',
    'appointment_confirmed','preselection_message','workflow_en_route',
    'workflow_in_progress','workflow_completion_requested','workflow_completed',
    'appointment_reschedule_proposed','appointment_cancelled')
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
  v_workflow public.listing_workflows%rowtype;
  v_status text;
  v_recipient uuid;
  v_body text;
  v_type text;
begin
  if p_expected_revision is null or p_expected_revision < 0 then
    raise exception 'Güncel randevu sürümü gerekli' using errcode = '40001';
  end if;
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;
  if p_proposed_at is null then
    raise exception 'Geçerli bir tarih ve saat seçmelisin';
  end if;
  if p_proposed_at <= clock_timestamp() then
    raise exception 'Randevu zamanı gelecekte olmalı';
  end if;
  if not isfinite(p_proposed_at) or p_proposed_at > clock_timestamp() + interval '90 days' then
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

  -- Shared lock order: listing -> workflow -> appointment. All workflow RPCs
  -- already serialize on the listing, including concurrent travel/cancel actions.
  select * into v_workflow from public.listing_workflows
  where listing_id = p_listing_id for update;
  if v_workflow.listing_id is null
     or v_workflow.customer_id <> v_listing.owner
     or v_workflow.professional_id <> v_quote.pro
     or v_workflow.state not in ('awaiting_appointment','scheduled')
     or public.is_blocked(v_listing.owner, v_quote.pro)
     or (select count(*) from public.profiles
         where id in (v_listing.owner,v_quote.pro) and account_status = 'active') <> 2 then
    raise exception 'Taraflar bu randevuyu değiştiremez' using errcode = '42501';
  end if;

  select * into v_current
  from public.listing_appointments
  where listing_id = p_listing_id
  for update;

  if v_current.id is not null and
     (v_current.customer_id <> v_listing.owner or v_current.professional_id <> v_quote.pro) then
    raise exception 'Randevu tarafları değişmiş' using errcode = '42501';
  end if;
  v_type := case when v_workflow.state = 'scheduled'
    then 'appointment_reschedule_proposed' else 'appointment_proposed' end;
  v_status := case when v_uid = v_listing.owner
    then 'awaiting_expert' else 'awaiting_customer' end;

  -- Safe retry: the same proposal does not increment the revision or notify twice.
  if v_current.id is not null
     and v_current.revision = p_expected_revision + 1
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
    if v_current.revision is distinct from p_expected_revision then
      raise exception 'Randevu bilgisi değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
    end if;
    if v_current.status = 'cancelled' and v_uid <> v_listing.owner then
      raise exception 'İptal sonrası ilk öneriyi müşteri oluşturmalı' using errcode = '42501';
    end if;
    if v_uid = v_listing.owner and v_current.status not in ('awaiting_customer','confirmed','cancelled') then
      raise exception 'Uzmanın yanıtı bekleniyor';
    end if;
    if v_uid = v_quote.pro and v_current.status not in ('awaiting_expert','confirmed') then
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
  values(v_recipient,v_type,'Yeni randevu önerisi',v_body,p_listing_id,v_uid);

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
  v_workflow public.listing_workflows%rowtype;
  v_recipient uuid;
begin
  if p_expected_revision is null or p_expected_revision < 0 then
    raise exception 'Güncel randevu sürümü gerekli' using errcode = '40001';
  end if;
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

  -- Shared lock order: listing -> workflow -> appointment. All workflow RPCs
  -- already serialize on the listing, including concurrent travel/cancel actions.
  select * into v_workflow from public.listing_workflows
  where listing_id = p_listing_id for update;
  if v_workflow.listing_id is null
     or v_workflow.customer_id <> v_listing.owner
     or v_workflow.professional_id <> v_quote.pro
     or v_workflow.state not in ('awaiting_appointment','scheduled')
     or public.is_blocked(v_listing.owner, v_quote.pro)
     or (select count(*) from public.profiles
         where id in (v_listing.owner,v_quote.pro) and account_status = 'active') <> 2 then
    raise exception 'Taraflar bu randevuyu değiştiremez' using errcode = '42501';
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

  if v_current.revision is distinct from p_expected_revision then
    raise exception 'Randevu bilgisi değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
  end if;
  if v_current.proposed_at <= clock_timestamp() then
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

create or replace function public.cancel_listing_appointment(
  p_listing_id bigint,
  p_expected_revision bigint,
  p_cancel_reason text default null
)
returns public.listing_appointments
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_workflow public.listing_workflows%rowtype;
  v_current public.listing_appointments%rowtype;
  v_result public.listing_appointments%rowtype;
  v_reason text := nullif(btrim(p_cancel_reason),'');
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;
  if p_expected_revision is null or p_expected_revision < 1 then
    raise exception 'Güncel randevu sürümü gerekli' using errcode = '40001';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'İptal nedeni en fazla 500 karakter olabilir' using errcode = '22023';
  end if;
  select * into v_listing from public.listings where id = p_listing_id for update;
  if v_listing.id is null or v_listing.status <> 'chosen' or v_listing.chosen_quote is null then
    raise exception 'Aktif randevu bulunamadı' using errcode = '42501';
  end if;
  select * into v_quote from public.quotes
  where id = v_listing.chosen_quote and listing_id = p_listing_id;
  if v_quote.id is null or v_uid not in (v_listing.owner,v_quote.pro) then
    raise exception 'Bu randevu için yetkin yok' using errcode = '42501';
  end if;
  -- Shared lock order: listing -> workflow -> appointment. All workflow RPCs
  -- already serialize on the listing, including concurrent travel/cancel actions.
  select * into v_workflow from public.listing_workflows
  where listing_id = p_listing_id for update;
  if v_workflow.listing_id is null
     or v_workflow.customer_id <> v_listing.owner
     or v_workflow.professional_id <> v_quote.pro
     or v_workflow.state not in ('awaiting_appointment','scheduled')
     or public.is_blocked(v_listing.owner, v_quote.pro)
     or (select count(*) from public.profiles
         where id in (v_listing.owner,v_quote.pro) and account_status = 'active') <> 2 then
    raise exception 'Taraflar bu randevuyu değiştiremez' using errcode = '42501';
  end if;


  select * into v_current from public.listing_appointments
  where listing_id = p_listing_id for update;
  if v_current.id is null or v_current.customer_id <> v_listing.owner
     or v_current.professional_id <> v_quote.pro then
    raise exception 'Aktif randevu bulunamadı' using errcode = '42501';
  end if;
  if v_current.status = 'cancelled' and v_current.cancelled_by = v_uid
     and v_current.revision = p_expected_revision + 1
     and v_current.cancel_reason is not distinct from v_reason then
    return v_current;
  end if;
  if v_current.revision is distinct from p_expected_revision then
    raise exception 'Randevu bilgisi değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
  end if;
  if v_current.status = 'cancelled' then
    raise exception 'Randevu zaten iptal edildi' using errcode = '22023';
  end if;
  update public.listing_appointments
  set status = 'cancelled', revision = revision + 1, confirmed_at = null,
      cancelled_at = now(), cancelled_by = v_uid, cancel_reason = v_reason,
      updated_at = now()
  where id = v_current.id returning * into v_result;
  -- Never interpolate the untrusted reason in notifications.
  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(case when v_uid = v_listing.owner then v_quote.pro else v_listing.owner end,
    'appointment_cancelled','Randevu iptal edildi',
    'Randevu iptal edildi. İş ve seçilen uzman değişmedi; yeni randevu oluşturabilirsiniz.',
    p_listing_id,v_uid);
  return v_result;
end;
$$;


create or replace function public.schedule_listing_workflow_from_appointment()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_workflow public.listing_workflows%rowtype;
  v_target text;
begin
  select * into v_workflow from public.listing_workflows
  where listing_id = new.listing_id for update;
  if v_workflow.listing_id is null
     or v_workflow.customer_id <> new.customer_id
     or v_workflow.professional_id <> new.professional_id
     or v_workflow.state not in ('awaiting_appointment','scheduled') then
    raise exception 'İş akışı randevu değişikliğine uygun değil' using errcode = '40001';
  end if;

  if new.status = 'confirmed' then
    v_target := 'scheduled';
  elsif new.status = 'cancelled' then
    v_target := 'awaiting_appointment';
  elsif v_workflow.state = 'scheduled' then
    -- Keep scheduled during negotiation, but invalidate stale workflow actions.
    v_target := 'scheduled';
  else
    return new; -- Initial/restarted pending proposal: no workflow transition.
  end if;

  update public.listing_workflows
  set state = v_target, revision = revision + 1,
      last_actor_id = auth.uid(),
      last_action = case when new.status = 'confirmed' then 'appointment_confirmed'
                         when new.status = 'cancelled' then 'appointment_cancelled'
                         else 'appointment_reschedule_proposed' end,
      last_client_request_id = null, updated_at = now()
  where listing_id = new.listing_id;
  return new;
end;
$$;


create or replace function public.advance_listing_workflow(
  p_listing_id bigint,
  p_target_state text,
  p_expected_revision bigint,
  p_client_request_id uuid
)
returns public.listing_workflows
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_workflow public.listing_workflows%rowtype;
  v_result public.listing_workflows%rowtype;
  v_expected_state text;
  v_required_actor uuid;
  v_recipient uuid;
  v_type text;
  v_title text;
  v_body text;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;
  if p_client_request_id is null then
    raise exception 'İstek kimliği gerekli';
  end if;
  if p_target_state not in ('en_route','in_progress','completion_requested','completed') then
    raise exception 'Geçersiz iş durumu';
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id
  for update;

  if v_listing.id is null or v_listing.chosen_quote is null then
    raise exception 'Seçilmiş uzmanı olan bir iş bulunamadı' using errcode = '42501';
  end if;

  select * into v_quote
  from public.quotes
  where id = v_listing.chosen_quote and listing_id = v_listing.id;

  select * into v_workflow
  from public.listing_workflows
  where listing_id = p_listing_id
  for update;

  if v_quote.id is null or v_workflow.listing_id is null
     or v_workflow.customer_id <> v_listing.owner
     or v_workflow.professional_id <> v_quote.pro
     or v_uid not in (v_listing.owner, v_quote.pro) then
    raise exception 'Bu iş akışı için yetkin yok' using errcode = '42501';
  end if;

  if v_workflow.last_actor_id = v_uid
     and v_workflow.last_client_request_id = p_client_request_id then
    if v_workflow.last_action = p_target_state then
      return v_workflow;
    end if;
    raise exception 'İstek kimliği başka bir işlemde kullanılmış';
  end if;

  if v_listing.status <> 'chosen'
     or public.is_blocked(v_listing.owner, v_quote.pro)
     or (
       select count(*) from public.profiles p
       where p.id in (v_listing.owner, v_quote.pro)
         and p.account_status = 'active'
     ) <> 2 then
    raise exception 'Taraflar bu iş akışını değiştiremez' using errcode = '42501';
  end if;

  if v_workflow.revision <> p_expected_revision then
    raise exception 'İş durumu değişti. Ekranı yenileyip tekrar dene' using errcode = '40001';
  end if;

  case p_target_state
    when 'en_route' then
      v_expected_state := 'scheduled';
      v_required_actor := v_quote.pro;
      v_recipient := v_listing.owner;
      v_type := 'workflow_en_route';
      v_title := 'Uzman yola çıktı';
      v_body := 'Seçtiğin uzman randevu için yola çıktı.';
    when 'in_progress' then
      v_expected_state := 'en_route';
      v_required_actor := v_quote.pro;
      v_recipient := v_listing.owner;
      v_type := 'workflow_in_progress';
      v_title := 'İş başladı';
      v_body := 'Seçtiğin uzman işe başladığını bildirdi.';
    when 'completion_requested' then
      v_expected_state := 'in_progress';
      v_required_actor := v_quote.pro;
      v_recipient := v_listing.owner;
      v_type := 'workflow_completion_requested';
      v_title := 'Uzman tamamlandığını bildirdi';
      v_body := 'Uzman işi tamamladığını bildirdi. Onayını bekliyor.';
    when 'completed' then
      v_expected_state := 'completion_requested';
      v_required_actor := v_listing.owner;
      v_recipient := v_quote.pro;
      v_type := 'workflow_completed';
      v_title := 'Müşteri işi onayladı';
      v_body := 'Müşteri işin tamamlandığını onayladı.';
  end case;

  if v_uid <> v_required_actor then
    raise exception 'Bu durum değişikliğini yapmaya yetkin yok' using errcode = '42501';
  end if;
  if v_workflow.state <> v_expected_state then
    raise exception 'İş bu adıma geçmeye uygun değil';
  end if;

  -- A scheduled workflow may have an unaccepted reschedule proposal.
  -- Do not depart until the latest appointment is confirmed.
  if p_target_state = 'en_route' and not exists (
    select 1 from public.listing_appointments a
    where a.listing_id = p_listing_id and a.status = 'confirmed'
      and a.customer_id = v_listing.owner and a.professional_id = v_quote.pro
  ) then
    raise exception 'Güncel randevu onaylanmadan yola çıkılamaz' using errcode = '42501';
  end if;

  update public.listing_workflows
  set state = p_target_state,
      revision = revision + 1,
      last_actor_id = v_uid,
      last_action = p_target_state,
      last_client_request_id = p_client_request_id,
      updated_at = now(),
      completed_at = case when p_target_state = 'completed' then now() else null end
  where listing_id = p_listing_id
  returning * into v_result;

  if p_target_state = 'completed' then
    update public.listings
    set status = 'done'
    where id = p_listing_id
      and status = 'chosen'
      and chosen_quote = v_listing.chosen_quote;

    if not found then
      raise exception 'İlan tamamlanmaya uygun değil' using errcode = '40001';
    end if;
  end if;

  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(v_recipient,v_type,v_title,v_body,p_listing_id,v_uid);

  return v_result;
end;
$$;

-- Existing RLS remains parties-only SELECT, with no client table mutations.
revoke all on function public.propose_listing_appointment(bigint,timestamptz,bigint) from public,anon;
revoke all on function public.accept_listing_appointment(bigint,bigint) from public,anon;
revoke all on function public.cancel_listing_appointment(bigint,bigint,text) from public,anon;
revoke all on function public.schedule_listing_workflow_from_appointment() from public,anon,authenticated;
revoke all on function public.advance_listing_workflow(bigint,text,bigint,uuid) from public,anon;
grant execute on function public.propose_listing_appointment(bigint,timestamptz,bigint) to authenticated;
grant execute on function public.accept_listing_appointment(bigint,bigint) to authenticated;
grant execute on function public.cancel_listing_appointment(bigint,bigint,text) to authenticated;
grant execute on function public.advance_listing_workflow(bigint,text,bigint,uuid) to authenticated;
commit;
