begin;

create table if not exists public.payment_transactions (
  id uuid primary key default gen_random_uuid(),
  listing_id bigint not null unique references public.listings(id) on delete cascade,
  quote_id bigint not null references public.quotes(id) on delete restrict,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  pro_id uuid not null references public.profiles(id) on delete restrict,
  method text not null check (method in ('card','cash','deposit_cash')),
  currency text not null default 'TRY' check (currency='TRY'),
  gross_amount numeric(12,2) not null check (gross_amount >= 0),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  payable_amount numeric(12,2) not null check (payable_amount >= 0),
  deposit_percent smallint,
  provider_amount numeric(12,2) not null default 0 check (provider_amount >= 0),
  cash_amount numeric(12,2) not null default 0 check (cash_amount >= 0),
  partner_id uuid references public.partners(id) on delete set null,
  commission_percent numeric(5,2) not null default 0 check (commission_percent >= 0 and commission_percent <= 50),
  platform_commission_amount numeric(12,2) not null default 0 check (platform_commission_amount >= 0),
  partner_promo_contribution numeric(12,2) not null default 0 check (partner_promo_contribution >= 0),
  provider text,
  provider_payment_id text,
  provider_status text,
  status text not null default 'planned'
    check (status in ('planned','pending_provider','cash_pending','partially_paid','paid','failed','cancelled','refunded')),
  paid_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists payment_transactions_customer_idx on public.payment_transactions(customer_id,created_at desc);
create index if not exists payment_transactions_pro_idx on public.payment_transactions(pro_id,created_at desc);
create index if not exists payment_transactions_status_idx on public.payment_transactions(status,created_at desc);
create index if not exists payment_transactions_partner_idx on public.payment_transactions(partner_id,created_at desc);

alter table public.payment_transactions enable row level security;
grant select on public.payment_transactions to authenticated;
revoke insert,update,delete on public.payment_transactions from authenticated;
revoke all on public.payment_transactions from anon;

drop policy if exists payment_transactions_read_parties on public.payment_transactions;
create policy payment_transactions_read_parties
on public.payment_transactions for select to authenticated
using (
  customer_id=(select auth.uid())
  or pro_id=(select auth.uid())
  or public.is_admin()
);

create table if not exists public.payment_events (
  id bigint generated always as identity primary key,
  payment_id uuid not null references public.payment_transactions(id) on delete cascade,
  event_type text not null,
  old_status text,
  new_status text,
  note text,
  created_at timestamptz not null default now()
);

alter table public.payment_events enable row level security;
grant select on public.payment_events to authenticated;
revoke insert,update,delete on public.payment_events from authenticated;
revoke all on public.payment_events from anon;

drop policy if exists payment_events_read_parties on public.payment_events;
create policy payment_events_read_parties
on public.payment_events for select to authenticated
using (
  exists (
    select 1 from public.payment_transactions p
    where p.id=payment_id
      and (
        p.customer_id=(select auth.uid())
        or p.pro_id=(select auth.uid())
        or public.is_admin()
      )
  )
);

create or replace function public.sync_payment_transaction_from_choice()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_l public.listings%rowtype;
  v_q public.quotes%rowtype;
  v_partner public.partners%rowtype;
  v_payable numeric(12,2);
  v_provider numeric(12,2);
  v_cash numeric(12,2);
  v_commission_percent numeric(5,2):=0;
  v_commission numeric(12,2):=0;
  v_partner_contribution numeric(12,2):=0;
  v_status text;
  v_payment_id uuid;
  v_old_status text;
begin
  select * into v_l from public.listings where id=new.listing_id;
  select * into v_q from public.quotes where id=new.quote_id;
  if v_l.id is null or v_q.id is null then return new; end if;

  if v_l.partner_id is not null then
    select * into v_partner from public.partners where id=v_l.partner_id;
    v_commission_percent:=coalesce(v_partner.commission_percent,0);
    v_partner_contribution:=round((coalesce(new.discount_amount,0)*coalesce(v_partner.promo_share_percent,0)/100.0)::numeric,2);
  end if;

  v_payable:=greatest(v_q.price-coalesce(new.discount_amount,0),0);
  if new.method='card' then
    v_provider:=v_payable; v_cash:=0;
    v_status:='pending_provider';
  elsif new.method='cash' then
    v_provider:=0; v_cash:=v_payable;
    v_status:=case when new.cash_confirmed_at is not null then 'paid' else 'cash_pending' end;
  else
    v_provider:=round((v_payable*coalesce(new.deposit_percent,0)/100.0)::numeric,2);
    v_cash:=greatest(v_payable-v_provider,0);
    v_status:=case
      when new.cash_confirmed_at is not null and v_provider=0 then 'paid'
      else 'pending_provider'
    end;
  end if;

  v_commission:=round((v_payable*v_commission_percent/100.0)::numeric,2);

  select id,status into v_payment_id,v_old_status
  from public.payment_transactions
  where listing_id=new.listing_id;

  insert into public.payment_transactions(
    listing_id,quote_id,customer_id,pro_id,method,gross_amount,discount_amount,payable_amount,
    deposit_percent,provider_amount,cash_amount,partner_id,commission_percent,
    platform_commission_amount,partner_promo_contribution,status,paid_at,updated_at
  )
  values(
    new.listing_id,new.quote_id,new.customer_id,v_q.pro,new.method,v_q.price,coalesce(new.discount_amount,0),v_payable,
    new.deposit_percent,v_provider,v_cash,v_l.partner_id,v_commission_percent,
    v_commission,v_partner_contribution,v_status,
    case when v_status='paid' then coalesce(new.cash_confirmed_at,now()) else null end,now()
  )
  on conflict (listing_id) do update set
    quote_id=excluded.quote_id,
    customer_id=excluded.customer_id,
    pro_id=excluded.pro_id,
    method=excluded.method,
    gross_amount=excluded.gross_amount,
    discount_amount=excluded.discount_amount,
    payable_amount=excluded.payable_amount,
    deposit_percent=excluded.deposit_percent,
    provider_amount=excluded.provider_amount,
    cash_amount=excluded.cash_amount,
    partner_id=excluded.partner_id,
    commission_percent=excluded.commission_percent,
    platform_commission_amount=excluded.platform_commission_amount,
    partner_promo_contribution=excluded.partner_promo_contribution,
    status=case
      when payment_transactions.provider_status='paid' and excluded.cash_amount=0 then 'paid'
      when payment_transactions.provider_status='paid' and excluded.cash_amount>0 and new.cash_confirmed_at is not null then 'paid'
      when payment_transactions.provider_status='paid' and excluded.cash_amount>0 then 'partially_paid'
      else excluded.status
    end,
    paid_at=case
      when (
        (payment_transactions.provider_status='paid' and excluded.cash_amount=0)
        or
        (payment_transactions.provider_status='paid' and excluded.cash_amount>0 and new.cash_confirmed_at is not null)
        or
        (excluded.provider_amount=0 and new.cash_confirmed_at is not null)
      ) then coalesce(payment_transactions.paid_at,now())
      else null
    end,
    updated_at=now()
  returning id,status into v_payment_id,v_status;

  if v_old_status is distinct from v_status then
    insert into public.payment_events(payment_id,event_type,old_status,new_status,note)
    values(v_payment_id,'plan_sync',v_old_status,v_status,'Ödeme planı güncellendi');
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_payment_transaction on public.listing_payment_choices;
create trigger trg_sync_payment_transaction
after insert or update of method,deposit_percent,promotion_id,discount_amount,cash_confirmed_at
on public.listing_payment_choices
for each row execute function public.sync_payment_transaction_from_choice();

-- Existing selections are backfilled through a harmless update.
update public.listing_payment_choices
set discount_amount=discount_amount;

commit;
