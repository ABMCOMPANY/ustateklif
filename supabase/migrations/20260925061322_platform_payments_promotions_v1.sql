begin;

-- Payment methods on quotes
alter table public.quotes
  add column if not exists payment_methods text[] not null default array['card']::text[],
  add column if not exists deposit_percent smallint;

alter table public.quotes drop constraint if exists quotes_payment_methods_check;
alter table public.quotes add constraint quotes_payment_methods_check
check (
  cardinality(payment_methods) between 1 and 3
  and payment_methods <@ array['card','cash','deposit_cash']::text[]
);

alter table public.quotes drop constraint if exists quotes_deposit_percent_check;
alter table public.quotes add constraint quotes_deposit_percent_check
check (
  deposit_percent is null
  or deposit_percent between 1 and 90
);

-- Partner foundation
create table if not exists public.partners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  status text not null default 'active'
    check (status in ('active','paused','disabled')),
  created_at timestamptz not null default now()
);
alter table public.partners enable row level security;
grant select on public.partners to authenticated;
revoke all on public.partners from anon;

drop policy if exists partners_authenticated_read_active on public.partners;
create policy partners_authenticated_read_active
on public.partners for select to authenticated
using (status='active');

alter table public.listings
  add column if not exists source_kind text not null default 'consumer',
  add column if not exists partner_id uuid references public.partners(id) on delete set null,
  add column if not exists external_order_ref text;

alter table public.listings drop constraint if exists listings_source_kind_check;
alter table public.listings add constraint listings_source_kind_check
check (source_kind in ('consumer','partner','store'));

create index if not exists listings_partner_id_idx on public.listings(partner_id);
create index if not exists listings_external_order_ref_idx on public.listings(external_order_ref);

-- Promotions
create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  code text unique,
  title text not null,
  description text,
  discount_type text not null check (discount_type in ('fixed','percent')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  min_amount numeric(12,2) not null default 0 check (min_amount >= 0),
  max_discount numeric(12,2),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  total_limit integer,
  per_user_limit integer not null default 1 check (per_user_limit > 0),
  new_users_only boolean not null default false,
  categories text[] not null default '{}'::text[],
  cities text[] not null default '{}'::text[],
  partner_id uuid references public.partners(id) on delete set null,
  funded_by text not null default 'tamisim'
    check (funded_by in ('tamisim','partner','shared')),
  status text not null default 'active'
    check (status in ('draft','active','paused','ended')),
  created_at timestamptz not null default now()
);
alter table public.promotions enable row level security;
grant select on public.promotions to authenticated;
revoke all on public.promotions from anon;

drop policy if exists promotions_authenticated_read_active on public.promotions;
create policy promotions_authenticated_read_active
on public.promotions for select to authenticated
using (
  status='active'
  and starts_at <= now()
  and (ends_at is null or ends_at >= now())
);

create table if not exists public.promo_redemptions (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  listing_id bigint references public.listings(id) on delete set null,
  quote_id bigint references public.quotes(id) on delete set null,
  discount_amount numeric(12,2) not null check (discount_amount >= 0),
  created_at timestamptz not null default now()
);
alter table public.promo_redemptions enable row level security;
grant select on public.promo_redemptions to authenticated;
revoke insert, update, delete on public.promo_redemptions from authenticated;
revoke all on public.promo_redemptions from anon;

drop policy if exists promo_redemptions_read_own on public.promo_redemptions;
create policy promo_redemptions_read_own
on public.promo_redemptions for select to authenticated
using (user_id=(select auth.uid()));

create index if not exists promo_redemptions_user_idx on public.promo_redemptions(user_id);
create index if not exists promo_redemptions_promotion_idx on public.promo_redemptions(promotion_id);

-- Customer payment choice
create table if not exists public.listing_payment_choices (
  listing_id bigint primary key references public.listings(id) on delete cascade,
  quote_id bigint not null references public.quotes(id) on delete restrict,
  customer_id uuid not null references auth.users(id) on delete cascade,
  method text not null check (method in ('card','cash','deposit_cash')),
  deposit_percent smallint,
  promotion_id uuid references public.promotions(id) on delete set null,
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  created_at timestamptz not null default now()
);
alter table public.listing_payment_choices enable row level security;
grant select, insert on public.listing_payment_choices to authenticated;
revoke update, delete on public.listing_payment_choices from authenticated;
revoke all on public.listing_payment_choices from anon;

alter table public.listing_payment_choices drop constraint if exists listing_payment_choices_deposit_check;
alter table public.listing_payment_choices add constraint listing_payment_choices_deposit_check
check (
  (method <> 'deposit_cash' and deposit_percent is null)
  or
  (method='deposit_cash' and deposit_percent between 1 and 90)
);

drop policy if exists payment_choice_insert_listing_owner on public.listing_payment_choices;
create policy payment_choice_insert_listing_owner
on public.listing_payment_choices for insert to authenticated
with check (
  customer_id=(select auth.uid())
  and exists (
    select 1 from public.listings l
    where l.id=listing_id
      and l.owner=(select auth.uid())
      and l.chosen_quote=quote_id
  )
  and exists (
    select 1 from public.quotes q
    where q.id=quote_id
      and q.listing_id=listing_id
      and method=any(q.payment_methods)
      and (
        (method='deposit_cash' and deposit_percent=q.deposit_percent)
        or
        (method<>'deposit_cash' and deposit_percent is null)
      )
  )
);

drop policy if exists payment_choice_read_parties on public.listing_payment_choices;
create policy payment_choice_read_parties
on public.listing_payment_choices for select to authenticated
using (
  customer_id=(select auth.uid())
  or exists (
    select 1 from public.quotes q
    where q.id=quote_id and q.pro=(select auth.uid())
  )
);

commit;
