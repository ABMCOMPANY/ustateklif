-- Tamİşim v12 — engellenmiş ilişkide mesaj sertleştirmesi
-- Paket 4 gerçek saldırı testi, mesaj INSERT politikasında göndericiye dayalı
-- kontrolün karşı taraf engelini atlayabildiğini gösterdi.

drop policy if exists "mesaj okuma" on public.messages;
drop policy if exists "mesaj ekleme" on public.messages;

-- Seçili işin iki tarafı mesajları ancak aralarında aktif engel yoksa görebilir.
create policy "mesaj okuma" on public.messages
for select to authenticated
using (
  public.is_party(listing_id)
  and not public.is_blocked(
    auth.uid(),
    (
      select case
        when l.owner = auth.uid() then q.pro
        else l.owner
      end
      from public.listings l
      left join public.quotes q on q.id = l.chosen_quote
      where l.id = listing_id
    )
  )
);

-- Mesaj gönderen kişi kendisi olmalı, seçili işin tarafı olmalı ve
-- işin karşı tarafıyla iki yönlü engel bulunmamalı.
create policy "mesaj ekleme" on public.messages
for insert to authenticated
with check (
  public.is_active_user()
  and sender = auth.uid()
  and public.is_party(listing_id)
  and not public.is_blocked(
    auth.uid(),
    (
      select case
        when l.owner = auth.uid() then q.pro
        else l.owner
      end
      from public.listings l
      left join public.quotes q on q.id = l.chosen_quote
      where l.id = listing_id
    )
  )
);
