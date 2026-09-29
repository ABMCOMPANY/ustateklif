begin;

-- Sprint 6A-1: immutable selection baseline, post-selection lifecycle and
-- verified reviews. Existing listings.status remains open/chosen/done.

create table if not exists public.listing_workflows (
  listing_id bigint primary key references public.listings(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  state text not null,
  revision bigint not null default 1,
  last_actor_id uuid references public.profiles(id) on delete set null,
  last_action text,
  last_client_request_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint listing_workflows_distinct_parties check (customer_id <> professional_id),
  constraint listing_workflows_state_check check (
    state in ('awaiting_appointment','scheduled','en_route','in_progress','completion_requested','completed')
  ),
  constraint listing_workflows_revision_check check (revision > 0),
  constraint listing_workflows_completion_check check (
    (state = 'completed' and completed_at is not null)
    or (state <> 'completed' and completed_at is null)
  ),
  constraint listing_workflows_last_actor_check check (
    last_actor_id is null or last_actor_id in (customer_id, professional_id)
  ),
  constraint listing_workflows_request_key unique (last_actor_id, last_client_request_id)
);

create index if not exists listing_workflows_customer_id_idx
  on public.listing_workflows(customer_id);
create index if not exists listing_workflows_professional_id_idx
  on public.listing_workflows(professional_id);

create table if not exists public.job_agreement_snapshots (
  listing_id bigint primary key references public.listings(id) on delete cascade,
  quote_id bigint not null unique references public.quotes(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  category text not null,
  service_problems text[] not null,
  listing_description text not null default '',
  quote_price integer not null,
  quote_eta text not null,
  quote_note text not null default '',
  quote_created_at timestamptz not null,
  selected_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint job_agreement_snapshots_distinct_parties check (customer_id <> professional_id),
  constraint job_agreement_snapshots_price_check check (quote_price > 0)
);

create index if not exists job_agreement_snapshots_customer_id_idx
  on public.job_agreement_snapshots(customer_id);
create index if not exists job_agreement_snapshots_professional_id_idx
  on public.job_agreement_snapshots(professional_id);

create table if not exists public.job_reviews (
  listing_id bigint primary key references public.listings(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  rating smallint not null,
  comment text,
  client_request_id uuid not null,
  created_at timestamptz not null default now(),
  constraint job_reviews_distinct_parties check (customer_id <> professional_id),
  constraint job_reviews_rating_check check (rating between 1 and 5),
  constraint job_reviews_comment_check check (comment is null or char_length(comment) <= 1000),
  constraint job_reviews_request_key unique (customer_id, client_request_id)
);

create index if not exists job_reviews_professional_id_idx
  on public.job_reviews(professional_id);

alter table public.listing_workflows enable row level security;
alter table public.job_agreement_snapshots enable row level security;
alter table public.job_reviews enable row level security;

revoke all on table public.listing_workflows from public, anon, authenticated;
revoke all on table public.job_agreement_snapshots from public, anon, authenticated;
revoke all on table public.job_reviews from public, anon, authenticated;
grant select on table public.listing_workflows to authenticated;
grant select on table public.job_agreement_snapshots to authenticated;
grant select on table public.job_reviews to authenticated;

drop policy if exists "workflow parties can read" on public.listing_workflows;
create policy "workflow parties can read"
on public.listing_workflows
for select
to authenticated
using (
  (select auth.uid()) is not null
  and (select auth.uid()) in (customer_id, professional_id)
);

drop policy if exists "agreement parties can read" on public.job_agreement_snapshots;
create policy "agreement parties can read"
on public.job_agreement_snapshots
for select
to authenticated
using (
  (select auth.uid()) is not null
  and (select auth.uid()) in (customer_id, professional_id)
);

drop policy if exists "review parties can read" on public.job_reviews;
create policy "review parties can read"
on public.job_reviews
for select
to authenticated
using (
  (select auth.uid()) is not null
  and (select auth.uid()) in (customer_id, professional_id)
);

-- Captures selection through every supported path, including the legacy
-- choose_quote_with_payment RPC. The trigger runs in the same transaction as
-- listings.chosen_quote, so a selection cannot commit without its baseline.
create or replace function public.capture_listing_job_baseline()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quote public.quotes%rowtype;
begin
  if new.status not in ('chosen','done') or new.chosen_quote is null then
    return new;
  end if;

  select * into v_quote
  from public.quotes
  where id = new.chosen_quote and listing_id = new.id;

  if v_quote.id is null or v_quote.pro = new.owner then
    raise exception 'Seçilen teklif ilanla eşleşmiyor' using errcode = '23514';
  end if;

  insert into public.job_agreement_snapshots(
    listing_id, quote_id, customer_id, professional_id, category,
    service_problems, listing_description, quote_price, quote_eta,
    quote_note, quote_created_at, selected_at
  ) values (
    new.id, v_quote.id, new.owner, v_quote.pro, new.category,
    new.problems, new.note, v_quote.price, v_quote.eta,
    v_quote.note, v_quote.created_at, now()
  ) on conflict (listing_id) do nothing;

  insert into public.listing_workflows(
    listing_id, customer_id, professional_id, state, revision,
    created_at, updated_at, completed_at
  ) values (
    new.id, new.owner, v_quote.pro,
    case when new.status = 'done' then 'completed' else 'awaiting_appointment' end,
    1, now(), now(), case when new.status = 'done' then now() else null end
  ) on conflict (listing_id) do nothing;

  return new;
end;
$$;

revoke all on function public.capture_listing_job_baseline() from public, anon, authenticated;

drop trigger if exists trg_capture_listing_job_baseline on public.listings;
create trigger trg_capture_listing_job_baseline
after insert or update of status, chosen_quote on public.listings
for each row execute function public.capture_listing_job_baseline();

-- Appointment confirmation advances only the workflow scheduling boundary.
create or replace function public.schedule_listing_workflow_from_appointment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changed bigint;
begin
  if new.status <> 'confirmed'
     or (tg_op = 'UPDATE' and old.status = 'confirmed') then
    return new;
  end if;

  update public.listing_workflows
  set state = 'scheduled',
      revision = revision + 1,
      last_actor_id = new.proposed_by,
      last_action = 'appointment_confirmed',
      last_client_request_id = null,
      updated_at = now()
  where listing_id = new.listing_id
    and customer_id = new.customer_id
    and professional_id = new.professional_id
    and state = 'awaiting_appointment';

  get diagnostics v_changed = row_count;
  if v_changed <> 1 then
    raise exception 'İş akışı randevu onayına uygun değil' using errcode = '40001';
  end if;

  return new;
end;
$$;

revoke all on function public.schedule_listing_workflow_from_appointment() from public, anon, authenticated;

drop trigger if exists trg_schedule_listing_workflow on public.listing_appointments;
create trigger trg_schedule_listing_workflow
after insert or update of status on public.listing_appointments
for each row execute function public.schedule_listing_workflow_from_appointment();

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (
  type in (
    'quote','chosen','message','nearby_job','appointment_proposed',
    'appointment_confirmed','preselection_message','workflow_en_route',
    'workflow_in_progress','workflow_completion_requested','workflow_completed'
  )
);

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

create or replace function public.submit_job_review(
  p_listing_id bigint,
  p_rating integer,
  p_comment text,
  p_client_request_id uuid
)
returns public.job_reviews
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.listings%rowtype;
  v_quote public.quotes%rowtype;
  v_workflow public.listing_workflows%rowtype;
  v_existing public.job_reviews%rowtype;
  v_result public.job_reviews%rowtype;
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;
  if p_client_request_id is null then
    raise exception 'İstek kimliği gerekli';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'Puan 1 ile 5 arasında olmalı';
  end if;
  if v_comment is not null and char_length(v_comment) > 1000 then
    raise exception 'Yorum en fazla 1000 karakter olabilir';
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id
  for update;

  if v_listing.id is null or v_listing.owner <> v_uid
     or v_listing.status <> 'done' or v_listing.chosen_quote is null then
    raise exception 'Bu iş için doğrulanmış yorum bırakamazsın' using errcode = '42501';
  end if;

  select * into v_quote
  from public.quotes
  where id = v_listing.chosen_quote and listing_id = v_listing.id;

  select * into v_workflow
  from public.listing_workflows
  where listing_id = p_listing_id
  for update;

  if v_quote.id is null or v_workflow.state <> 'completed'
     or v_workflow.customer_id <> v_uid
     or v_workflow.professional_id <> v_quote.pro then
    raise exception 'Bu iş için doğrulanmış yorum bırakamazsın' using errcode = '42501';
  end if;

  select * into v_existing
  from public.job_reviews
  where listing_id = p_listing_id
  for update;

  if v_existing.listing_id is not null then
    if v_existing.customer_id = v_uid
       and v_existing.client_request_id = p_client_request_id then
      return v_existing;
    end if;
    raise exception 'Bu iş için daha önce yorum yapıldı';
  end if;

  insert into public.job_reviews(
    listing_id, customer_id, professional_id, rating, comment, client_request_id
  ) values (
    p_listing_id, v_uid, v_quote.pro, p_rating, v_comment, p_client_request_id
  ) returning * into v_result;

  -- Keep the legacy aggregate path working without making listings.rating the
  -- source of review authorization.
  update public.listings set rating = p_rating where id = p_listing_id;

  return v_result;
end;
$$;

-- Cached clients must fail closed instead of bypassing the lifecycle or
-- coupling completion to a rating.
create or replace function public.complete_listing(
  p_listing_id bigint,
  p_rating integer
)
returns public.listings
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Aktif oturum gerekli' using errcode = '42501';
  end if;
  raise exception 'Bu işlem kaldırıldı. Güncel iş adımlarını kullanmalısın' using errcode = '0A000';
end;
$$;

revoke all on function public.advance_listing_workflow(bigint,text,bigint,uuid) from public, anon;
revoke all on function public.submit_job_review(bigint,integer,text,uuid) from public, anon;
revoke all on function public.complete_listing(bigint,integer) from public, anon;
grant execute on function public.advance_listing_workflow(bigint,text,bigint,uuid) to authenticated;
grant execute on function public.submit_job_review(bigint,integer,text,uuid) to authenticated;
grant execute on function public.complete_listing(bigint,integer) to authenticated;

-- Non-destructive legacy backfill. Dates are best available historical
-- evidence; no existing listing, quote, appointment or rating is changed.
insert into public.job_agreement_snapshots(
  listing_id, quote_id, customer_id, professional_id, category,
  service_problems, listing_description, quote_price, quote_eta,
  quote_note, quote_created_at, selected_at, created_at
)
select
  l.id, q.id, l.owner, q.pro, l.category,
  l.problems, l.note, q.price, q.eta,
  q.note, q.created_at,
  coalesce(a.created_at, pc.created_at, q.created_at, l.created_at),
  coalesce(a.created_at, pc.created_at, q.created_at, l.created_at)
from public.listings l
join public.quotes q on q.id = l.chosen_quote and q.listing_id = l.id
left join public.listing_appointments a on a.listing_id = l.id
left join public.listing_payment_choices pc on pc.listing_id = l.id
where l.status in ('chosen','done')
on conflict (listing_id) do nothing;

insert into public.listing_workflows(
  listing_id, customer_id, professional_id, state, revision,
  created_at, updated_at, completed_at
)
select
  l.id, l.owner, q.pro,
  case
    when l.status = 'done' then 'completed'
    when a.status = 'confirmed' then 'scheduled'
    else 'awaiting_appointment'
  end,
  1,
  coalesce(a.created_at, pc.created_at, q.created_at, l.created_at),
  coalesce(a.updated_at, pc.created_at, q.created_at, l.created_at),
  case when l.status = 'done'
    then coalesce(a.updated_at, pc.created_at, q.created_at, l.created_at)
    else null end
from public.listings l
join public.quotes q on q.id = l.chosen_quote and q.listing_id = l.id
left join public.listing_appointments a on a.listing_id = l.id
left join public.listing_payment_choices pc on pc.listing_id = l.id
where l.status in ('chosen','done')
on conflict (listing_id) do nothing;

insert into public.job_reviews(
  listing_id, customer_id, professional_id, rating, comment,
  client_request_id, created_at
)
select
  l.id, l.owner, q.pro, l.rating::smallint, null,
  gen_random_uuid(), l.created_at
from public.listings l
join public.quotes q on q.id = l.chosen_quote and q.listing_id = l.id
where l.status = 'done' and l.rating between 1 and 5
on conflict (listing_id) do nothing;

notify pgrst, 'reload schema';

commit;
