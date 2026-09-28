-- Sprint 5C: controlled messaging before quote selection.
-- Existing post-selection messages and their policies are intentionally untouched.

create schema if not exists preselection_security;
revoke all on schema preselection_security from public, anon, authenticated;

create table if not exists public.preselection_messages (
  id bigint generated always as identity primary key,
  listing_id bigint not null references public.listings(id) on delete cascade,
  quote_id bigint not null references public.quotes(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  client_request_id uuid not null,
  created_at timestamptz not null default now(),
  constraint preselection_messages_participant_check
    check (sender_id = customer_id or sender_id = professional_id),
  constraint preselection_messages_request_unique
    unique (sender_id, client_request_id)
);

create index if not exists preselection_messages_quote_created_idx
  on public.preselection_messages(quote_id, created_at, id);
create index if not exists preselection_messages_listing_idx
  on public.preselection_messages(listing_id);
create index if not exists preselection_messages_customer_idx
  on public.preselection_messages(customer_id);
create index if not exists preselection_messages_professional_idx
  on public.preselection_messages(professional_id);

alter table public.preselection_messages enable row level security;

drop policy if exists "preselection parties read" on public.preselection_messages;
create policy "preselection parties read"
on public.preselection_messages
for select
to authenticated
using (
  (select auth.uid()) is not null
  and ((select auth.uid()) = customer_id or (select auth.uid()) = professional_id)
);

revoke all on public.preselection_messages from public, anon, authenticated;
grant select on public.preselection_messages to authenticated;
revoke all on sequence public.preselection_messages_id_seq from public, anon, authenticated;

create or replace function preselection_security.contact_error(p_body text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body text := lower(coalesce(p_body, ''));
begin
  if v_body ~* '[[:alnum:]._%+\-]+[[:space:]]*@[[:space:]]*[[:alnum:].\-]+[[:space:]]*\.[[:space:]]*[[:alpha:]]{2,}' then
    return 'email';
  end if;

  if v_body ~* '(https?[[:space:]]*://|www[[:space:]]*\.|(^|[^[:alnum:]])t[[:space:]]*\.[[:space:]]*me([^[:alnum:]]|$)|(^|[^[:alnum:]])wa[[:space:]]*\.[[:space:]]*me([^[:alnum:]]|$))' then
    return 'link';
  end if;

  if v_body ~* '(whats[[:space:]._-]*app|telegram|instagram|insta[[:space:]._-]*gram|facebook|snapchat|tiktok)' then
    return 'social';
  end if;

  if v_body ~* '(^|[[:space:]])@[[:alnum:]_.]{3,}' then
    return 'social_handle';
  end if;

  if v_body ~* '(^|[^0-9])((\+|00)[[:space:]().-]*90[[:space:]().-]*)?0?[[:space:]().-]*[2-5][0-9]{2}([[:space:]().-]*[0-9]){7}([^0-9]|$)' then
    return 'phone';
  end if;

  return null;
end;
$$;

revoke all on function preselection_security.contact_error(text) from public, anon, authenticated;

create or replace function public.send_preselection_message(
  p_quote_id bigint,
  p_body text,
  p_client_request_id uuid
)
returns public.preselection_messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_quote public.quotes%rowtype;
  v_listing public.listings%rowtype;
  v_message public.preselection_messages%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
  v_recipient uuid;
  v_sender_name text;
  v_count integer;
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'preselection_auth_required';
  end if;

  if p_quote_id is null or p_client_request_id is null then
    raise exception using errcode = 'P0001', message = 'preselection_invalid_request';
  end if;

  select q.* into v_quote
  from public.quotes q
  where q.id = p_quote_id;

  if v_quote.id is null then
    raise exception using errcode = 'P0001', message = 'preselection_quote_not_found';
  end if;

  select l.* into v_listing
  from public.listings l
  where l.id = v_quote.listing_id
  for update;

  if v_listing.id is null then
    raise exception using errcode = 'P0001', message = 'preselection_listing_not_found';
  end if;

  if v_uid <> v_listing.owner and v_uid <> v_quote.pro then
    raise exception using errcode = '42501', message = 'preselection_forbidden';
  end if;

  select m.* into v_message
  from public.preselection_messages m
  where m.sender_id = v_uid
    and m.client_request_id = p_client_request_id;

  if v_message.id is not null then
    return v_message;
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_uid and p.account_status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'preselection_account_inactive';
  end if;

  if (
    select count(*)
    from public.profiles p
    where p.id in (v_listing.owner, v_quote.pro)
      and p.account_status = 'active'
  ) <> 2 then
    raise exception using errcode = '42501', message = 'preselection_party_inactive';
  end if;

  if exists (
    select 1 from public.user_blocks b
    where (b.blocker_id = v_listing.owner and b.blocked_id = v_quote.pro)
       or (b.blocker_id = v_quote.pro and b.blocked_id = v_listing.owner)
  ) then
    raise exception using errcode = '42501', message = 'preselection_blocked';
  end if;

  if v_listing.status <> 'open' or v_listing.chosen_quote is not null then
    raise exception using errcode = 'P0001', message = 'preselection_thread_closed';
  end if;

  if v_uid = v_quote.pro and not exists (
    select 1 from public.preselection_messages m
    where m.quote_id = v_quote.id
      and m.sender_id = v_listing.owner
  ) then
    raise exception using errcode = '42501', message = 'preselection_customer_must_start';
  end if;

  if char_length(v_body) < 1 or char_length(v_body) > 500 then
    raise exception using errcode = '22001', message = 'preselection_message_length';
  end if;

  if preselection_security.contact_error(v_body) is not null then
    raise exception using errcode = 'P0001', message = 'preselection_contact_forbidden';
  end if;

  select count(*)::integer into v_count
  from public.preselection_messages m
  where m.quote_id = v_quote.id and m.sender_id = v_uid;

  if v_count >= 10 then
    raise exception using errcode = 'P0001', message = 'preselection_message_limit';
  end if;

  insert into public.preselection_messages(
    listing_id, quote_id, customer_id, professional_id,
    sender_id, body, client_request_id
  ) values (
    v_listing.id, v_quote.id, v_listing.owner, v_quote.pro,
    v_uid, v_body, p_client_request_id
  )
  returning * into v_message;

  v_recipient := case when v_uid = v_listing.owner then v_quote.pro else v_listing.owner end;
  select p.name into v_sender_name from public.profiles p where p.id = v_uid;

  insert into public.notifications(user_id, type, title, body, listing_id, actor_id)
  values (
    v_recipient,
    'preselection_message',
    'Teklif hakkında yeni mesaj',
    case
      when v_uid = v_listing.owner then 'Müşteri teklifin hakkında bir soru gönderdi.'
      else coalesce(v_sender_name, 'Uzman') || ' teklifin hakkında cevap gönderdi.'
    end,
    v_listing.id,
    v_uid
  );

  return v_message;
end;
$$;

revoke all on function public.send_preselection_message(bigint, text, uuid)
  from public, anon, authenticated;
grant execute on function public.send_preselection_message(bigint, text, uuid)
  to authenticated;

alter table public.notifications
  drop constraint if exists notifications_type_check;

alter table public.notifications
  add constraint notifications_type_check check (
    type in (
      'quote', 'chosen', 'message', 'nearby_job',
      'appointment_proposed', 'appointment_confirmed',
      'preselection_message'
    )
  );

comment on table public.preselection_messages is
  'Short quote-specific customer/professional threads before quote selection.';
comment on function public.send_preselection_message(bigint, text, uuid) is
  'Sends a controlled, idempotent pre-selection message. Customer must start the thread.';
