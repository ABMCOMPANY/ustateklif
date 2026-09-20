-- UstaTeklif v4 - Usta profili güncellemesi
-- Mevcut Supabase projesinde SQL Editor'da bir kez çalıştır.

alter table public.profiles add column if not exists bio text not null default '';
alter table public.profiles add column if not exists services text[] not null default '{}';
alter table public.profiles add column if not exists service_areas text[] not null default '{}';

-- İstemcinin yalnızca kendi profilini değiştirebildiği mevcut RLS politikası bu alanları da kapsar.
-- Tamamlanan iş sayısı ve puan, mevcut pro_stats görünümünden hesaplanmaya devam eder.
