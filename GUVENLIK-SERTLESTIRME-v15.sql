-- Tamİşim v15 — bildirim UPDATE yetkisini yalnız read_at alanına indir
-- Paket 6: kullanıcı kendi bildiriminin title/body/type alanlarını değiştirebiliyordu.

-- Önce tablo seviyesindeki geniş UPDATE yetkisini kaldır.
revoke update on public.notifications from authenticated;

-- Kullanıcı yalnızca kendi bildiriminin read_at alanını güncelleyebilsin.
grant update (read_at) on public.notifications to authenticated;

-- RLS yine yalnız kullanıcının kendi bildirim satırına izin verir.
drop policy if exists "bildirim guncelleme" on public.notifications;
create policy "bildirim guncelleme" on public.notifications
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());
