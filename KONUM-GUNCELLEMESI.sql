-- UstaTeklif v5 - Yapılandırılmış konum güncellemesi
-- Mevcut Supabase projesinde SQL Editor'da bir kez çalıştır.

alter table public.listings add column if not exists city text not null default '';
alter table public.listings add column if not exists district text not null default '';
alter table public.listings add column if not exists neighborhood text not null default '';

alter table public.profiles add column if not exists service_city text not null default '';
alter table public.profiles add column if not exists service_districts text[] not null default '{}';

create index if not exists listings_location_idx on public.listings(status, city, district);

-- Eski ilanların tek parça "area" bilgisi korunur. Yeni ilanlar city/district/neighborhood
-- alanlarını doldurur ve area alanına da okunabilir tam konum yazar.
