
begin;

create table if not exists public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payment_transactions(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  provider text,
  amount numeric(12,2) not null check (amount >= 0),
  currency text not null default 'TRY' check (currency='TRY'),
  status text not null default 'created'
    check (status in ('created','provider_pending','redirected','authorized','paid','failed','cancelled','expired')),
  idempotency_key uuid not null default gen_random_uuid() unique,
  provider_session_id text,
  provider_payment_id text,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists payment_attempts_payment_idx on public.payment_attempts(payment_id,created_at desc);
create index if not exists payment_attempts_customer_idx on public.payment_attempts(customer_id,created_at desc);

alter table public.payment_attempts enable row level security;
grant select on public.payment_attempts to authenticated;
revoke insert,update,delete on public.payment_attempts from authenticated;
revoke all on public.payment_attempts from anon;

drop policy if exists payment_attempts_read_parties on public.payment_attempts;
create policy payment_attempts_read_parties
on public.payment_attempts for select to authenticated
using (
  customer_id=(select auth.uid())
  or exists (
    select 1 from public.payment_transactions p
    where p.id=payment_id and (p.pro_id=(select auth.uid()) or public.is_admin())
  )
);

create or replace function public.admin_payment_stats()
returns jsonb
language sql
security definer
set search_path=public
as $$
  select case when public.is_admin() then jsonb_build_object(
    'payments', count(*),
    'pending', count(*) filter (where status not in ('paid','refunded','cancelled')),
    'paid', count(*) filter (where status='paid'),
    'failed', count(*) filter (where status='failed'),
    'net_volume', coalesce(sum(payable_amount),0),
    'commission', coalesce(sum(platform_commission_amount),0),
    'provider_volume', coalesce(sum(provider_amount),0),
    'cash_volume', coalesce(sum(cash_amount),0)
  ) else '{}'::jsonb end
  from public.payment_transactions;
$$;

revoke all on function public.admin_payment_stats() from public,anon;
grant execute on function public.admin_payment_stats() to authenticated;

commit;
