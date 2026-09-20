-- UstaTeklif v8 — güven, doğrulama, şikâyet ve engelleme
-- Mevcut v7 Supabase projesinde SQL Editor'da bir kez çalıştırın.

alter table public.profiles add column if not exists phone_verified boolean not null default false;
alter table public.profiles add column if not exists identity_verified boolean not null default false;

-- Doğrulama alanları istemciden değiştirilemez. Profilin yalnızca kullanıcı tarafından
-- düzenlenebilir alanlarına kolon seviyesinde UPDATE izni verilir.
revoke update on public.profiles from authenticated;
grant update (name,title,bio,services,service_areas,service_city,service_districts) on public.profiles to authenticated;

create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists user_blocks_blocked_idx on public.user_blocks(blocked_id);
alter table public.user_blocks enable row level security;
drop policy if exists "engellerimi oku" on public.user_blocks;
drop policy if exists "kullanici engelle" on public.user_blocks;
drop policy if exists "engeli kaldir" on public.user_blocks;
create policy "engellerimi oku" on public.user_blocks for select to authenticated using (blocker_id=auth.uid());
create policy "kullanici engelle" on public.user_blocks for insert to authenticated with check (blocker_id=auth.uid() and blocked_id<>auth.uid());
create policy "engeli kaldir" on public.user_blocks for delete to authenticated using (blocker_id=auth.uid());
grant select,insert,delete on public.user_blocks to authenticated;

create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid not null references public.profiles(id) on delete cascade,
  listing_id bigint references public.listings(id) on delete set null,
  reason text not null check (char_length(reason) between 10 and 500),
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now(),
  check (reporter_id <> reported_id)
);
create index if not exists reports_status_idx on public.reports(status,created_at desc);
alter table public.reports enable row level security;
drop policy if exists "sikayet olustur" on public.reports;
create policy "sikayet olustur" on public.reports for insert to authenticated with check (reporter_id=auth.uid() and reported_id<>auth.uid());
-- Şikâyet kayıtları uygulama kullanıcılarına listelenmez; yönetim/service-role tarafında incelenir.
revoke select,update,delete on public.reports from authenticated;
grant insert on public.reports to authenticated;
grant usage,select on all sequences in schema public to authenticated;

-- İki kullanıcıdan biri diğerini engellediyse true.
create or replace function public.is_blocked(a uuid,b uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from public.user_blocks x where (x.blocker_id=a and x.blocked_id=b) or (x.blocker_id=b and x.blocked_id=a));
$$;
revoke all on function public.is_blocked(uuid,uuid) from public;
grant execute on function public.is_blocked(uuid,uuid) to authenticated;

-- Telefon rozeti auth.users içindeki gerçek phone_confirmed_at alanından türetilir.
create or replace function public.sync_my_verification()
returns public.profiles language plpgsql security definer set search_path=public,auth as $$
declare r public.profiles;
begin
  if auth.uid() is null then raise exception 'Oturum gerekli'; end if;
  update public.profiles p
     set phone_verified = exists(select 1 from auth.users u where u.id=auth.uid() and u.phone_confirmed_at is not null)
   where p.id=auth.uid()
  returning p.* into r;
  return r;
end $$;
revoke all on function public.sync_my_verification() from public;
grant execute on function public.sync_my_verification() to authenticated;

-- Engellenen kullanıcılar arasında yeni ilan/teklif/mesaj etkileşimini kes.
drop policy if exists "ilan okuma" on public.listings;
create policy "ilan okuma" on public.listings for select to authenticated
  using (owner=auth.uid() or not public.is_blocked(auth.uid(),owner));

drop policy if exists "teklif okuma" on public.quotes;
create policy "teklif okuma" on public.quotes for select to authenticated using (
  (pro=auth.uid() and not public.is_blocked(auth.uid(),(select owner from public.listings l where l.id=listing_id)))
  or exists(select 1 from public.listings l where l.id=listing_id and l.owner=auth.uid() and not public.is_blocked(auth.uid(),pro))
);
drop policy if exists "teklif ekleme" on public.quotes;
create policy "teklif ekleme" on public.quotes for insert to authenticated with check (
  pro=auth.uid() and exists(select 1 from public.listings l where l.id=listing_id and l.status='open' and l.owner<>auth.uid() and not public.is_blocked(auth.uid(),l.owner))
);

drop policy if exists "mesaj okuma" on public.messages;
drop policy if exists "mesaj ekleme" on public.messages;
create policy "mesaj okuma" on public.messages for select to authenticated using (
  public.is_party(listing_id) and not public.is_blocked(auth.uid(),sender)
);
create policy "mesaj ekleme" on public.messages for insert to authenticated with check (
  sender=auth.uid() and public.is_party(listing_id) and not public.is_blocked(auth.uid(),
    (select case when l.owner=auth.uid() then q.pro else l.owner end from public.listings l left join public.quotes q on q.id=l.chosen_quote where l.id=listing_id)
  )
);
