-- Tamİşim platform temel altyapısı v1
-- Ödeme tercihleri + partner kaynakları + promosyon + çok katmanlı uzman doğrulama.
-- Geriye uyumludur: mevcut ilan/teklif akışını bozmaz.

begin;

-- 1) Partner / kurumsal iş kaynağı
create table if not exists public.partners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  status text not null default 'active' check (status in ('active','paused','disabled')),
  created_at timestamptz not null default now()
);

alter table public.partners enable row level security;

drop policy if exists "partners_authenticated_read_active" on public.partners;
create policy "partners_authenticated_read_active"
on public.partners for select
to authenticated
using (status = 'active');

-- İlan bireysel mi, partnerden mi geldi?
alter table public.listings
  add column if not exists source_kind text not null default 'consumer',
  add column if not exists partner_id uuid references public.partners(id) on delete set null,
  add column if not exists external_order_ref text;

alter table public.listings
  drop constraint if exists listings_source_kind_check;
alter table public.listings
  add constraint listings_source_kind_check
  check (source_kind in ('consumer','partner','store'));

create index if not exists listings_partner_id_idx on public.listings(partner_id);
create index if not exists listings_external_order_ref_idx on public.listings(external_order_ref);

-- 2) Uzmanın teklif bazında kabul ettiği ödeme yöntemleri
alter table public.quotes
  add column if not exists payment_methods text[] not null default array['card']::text[],
  add column if not exists deposit_percent smallint;

alter table public.quotes
  drop constraint if exists quotes_deposit_percent_check;
alter table public.quotes
  add constraint quotes_deposit_percent_check
  check (deposit_percent is null or deposit_percent between 1 and 90);

-- Kart / nakit / ön ödeme + kalan nakit
alter table public.quotes
  drop constraint if exists quotes_payment_methods_check;
alter table public.quotes
  add constraint quotes_payment_methods_check
  check (
    cardinality(payment_methods) between 1 and 3
    and payment_methods <@ array['card','cash','deposit_cash']::text[]
  );

-- 3) Promosyon / kampanya altyapısı
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

drop policy if exists "promotions_authenticated_read_active" on public.promotions;
create policy "promotions_authenticated_read_active"
on public.promotions for select
to authenticated
using (
  status = 'active'
  and starts_at <= now()
  and (ends_at is null or ends_at >= now())
);

create table if not exists public.promo_redemptions (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  listing_id uuid references public.listings(id) on delete set null,
  quote_id uuid references public.quotes(id) on delete set null,
  discount_amount numeric(12,2) not null check (discount_amount >= 0),
  created_at timestamptz not null default now()
);

alter table public.promo_redemptions enable row level security;

drop policy if exists "promo_redemptions_read_own" on public.promo_redemptions;
create policy "promo_redemptions_read_own"
on public.promo_redemptions for select
to authenticated
using (user_id = auth.uid());

create index if not exists promo_redemptions_user_idx on public.promo_redemptions(user_id);
create index if not exists promo_redemptions_promotion_idx on public.promo_redemptions(promotion_id);

-- İstemcinin kendi kendine indirim kaydı üretmesini engelle.
revoke insert, update, delete on public.promo_redemptions from authenticated;

-- 4) Çok katmanlı uzman doğrulama
create table if not exists public.professional_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null,
  verification_type text not null
    check (verification_type in ('identity','vocational','diploma','certificate','business')),
  document_type text,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','expired')),
  reviewed_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  unique(user_id, category, verification_type)
);

alter table public.professional_verifications enable row level security;

drop policy if exists "professional_verifications_read_own" on public.professional_verifications;
create policy "professional_verifications_read_own"
on public.professional_verifications for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "professional_verifications_insert_own_pending" on public.professional_verifications;
create policy "professional_verifications_insert_own_pending"
on public.professional_verifications for insert
to authenticated
with check (
  user_id = auth.uid()
  and status = 'pending'
  and reviewed_at is null
);

-- Kullanıcı gönderdiği doğrulamanın sonucunu kendisi değiştiremez.
revoke update, delete on public.professional_verifications from authenticated;

create index if not exists professional_verifications_user_idx
  on public.professional_verifications(user_id);

-- 5) Profilde hızlı rozet gösterimi için özet alanlar.
-- identity_verified zaten varsa korunur.
alter table public.profiles
  add column if not exists vocational_verified boolean not null default false,
  add column if not exists business_verified boolean not null default false;

commit;
