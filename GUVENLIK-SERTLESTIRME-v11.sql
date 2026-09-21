-- Tamİşim v11 — kritik INSERT yetkileri ve ilk durum sertleştirmesi
-- v10 sonrasında bir kez çalıştırın.
-- Amaç: normal kullanıcının INSERT sırasında doğrulama/hesap durumu veya
-- ilan iş-akışı alanlarını sahte değerlerle oluşturmasını engellemek.

-- Profiller normalde auth.users tetikleyicisi tarafından oluşturulur.
-- İstemci tarafının profile doğrudan INSERT yapmasına gerek yoktur.
revoke insert on public.profiles from authenticated;

-- İlan oluşturulurken iş akışı her zaman güvenli başlangıç durumunda olmalı.
drop policy if exists "ilan ekleme" on public.listings;
create policy "ilan ekleme" on public.listings
for insert to authenticated
with check (
  owner = auth.uid()
  and public.is_active_user()
  and status = 'open'
  and chosen_quote is null
  and rating is null
);

-- Savunma katmanı: normal kullanıcı yalnızca ilan oluşturmak için gereken
-- kolonlara INSERT yapabilsin. status/chosen_quote/rating/created_at yazamaz.
revoke insert on public.listings from authenticated;
grant insert (owner,category,problems,note,area,city,district,neighborhood,when_text)
on public.listings to authenticated;

-- Kritik profil kolonlarında INSERT yetkisi bulunmadığını doğrulamak için
-- aşağıdaki denetimi GUVENLIK-DENETIM-v11.sql ile çalıştırın.
