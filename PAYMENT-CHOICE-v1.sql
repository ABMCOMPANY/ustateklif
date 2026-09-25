-- Tamİşim müşteri ödeme yöntemi seçimi v1
-- Seçilen teklif için ödeme yöntemini kalıcı tutar.

begin;

create table if not exists public.listing_payment_choices (
  listing_id bigint primary key references public.listings(id) on delete cascade,
  quote_id bigint not null references public.quotes(id) on delete restrict,
  customer_id uuid not null references auth.users(id) on delete cascade,
  method text not null check (method in ('card','cash','deposit_cash')),
  deposit_percent smallint,
  created_at timestamptz not null default now()
);

alter table public.listing_payment_choices
  drop constraint if exists listing_payment_choices_deposit_check;
alter table public.listing_payment_choices
  add constraint listing_payment_choices_deposit_check
  check (
    (method <> 'deposit_cash' and deposit_percent is null)
    or
    (method = 'deposit_cash' and deposit_percent between 1 and 90)
  );

alter table public.listing_payment_choices enable row level security;

drop policy if exists "payment_choice_insert_listing_owner" on public.listing_payment_choices;
create policy "payment_choice_insert_listing_owner"
on public.listing_payment_choices for insert
to authenticated
with check (
  customer_id = auth.uid()
  and exists (
    select 1
    from public.listings l
    where l.id = listing_id
      and l.owner = auth.uid()
      and l.chosen_quote = quote_id
  )
  and exists (
    select 1
    from public.quotes q
    where q.id = quote_id
      and q.listing_id = listing_id
      and method = any(q.payment_methods)
  )
);

drop policy if exists "payment_choice_read_parties" on public.listing_payment_choices;
create policy "payment_choice_read_parties"
on public.listing_payment_choices for select
to authenticated
using (
  customer_id = auth.uid()
  or exists (
    select 1 from public.quotes q
    where q.id = quote_id and q.pro = auth.uid()
  )
);

revoke update, delete on public.listing_payment_choices from authenticated;

commit;
