-- Tamİşim v16 — ilan fotoğrafları gizlilik sertleştirmesi
-- Amaç: fotoğraf metadata/path ve Storage nesnelerini yalnızca ilanı görmeye
-- yetkili kullanıcıya açmak. Açık ilanlar uygulamada uzmanlara görünür;
-- engellenen ilişkiler ve askıdaki hesaplar erişemez.

-- Metadata: ilan sahibi veya uygulamada ilanı görmeye yetkili aktif kullanıcı.
drop policy if exists "ilan fotografi okuma" on public.listing_photos;
create policy "ilan fotografi okuma" on public.listing_photos
for select to authenticated
using (
  public.is_active_user()
  and exists (
    select 1
    from public.listings l
    where l.id = listing_photos.listing_id
      and (
        l.owner = auth.uid()
        or (
          l.status = 'open'
          and l.owner <> auth.uid()
          and not public.is_blocked(l.owner, auth.uid())
        )
        or public.is_party(l.id)
      )
  )
);

-- Storage SELECT aynı yetkilendirmeyi uygular.
-- Path biçimi: <owner_uuid>/<listing_id>/<dosya>
drop policy if exists "ilan fotograflari oku" on storage.objects;
create policy "ilan fotograflari oku" on storage.objects
for select to authenticated
using (
  bucket_id = 'listing-photos'
  and public.is_active_user()
  and (storage.foldername(name))[2] ~ '^[0-9]+$'
  and exists (
    select 1
    from public.listings l
    where l.id = ((storage.foldername(name))[2])::bigint
      and (storage.foldername(name))[1] = l.owner::text
      and (
        l.owner = auth.uid()
        or (
          l.status = 'open'
          and l.owner <> auth.uid()
          and not public.is_blocked(l.owner, auth.uid())
        )
        or public.is_party(l.id)
      )
  )
);

-- Upload/silme kuralları v10'daki sıkı haliyle korunur; burada yalnızca SELECT daraltılır.
