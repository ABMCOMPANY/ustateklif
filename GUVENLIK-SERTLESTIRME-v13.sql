-- Tamİşim v13 — engellenmiş ilişkide mesaj kontrolünü RLS'den bağımsızlaştır
-- v12'de messages politikası karşı tarafı public.listings üzerinden arıyordu.
-- listings RLS engellenen ilanı gizlediği için alt sorgu NULL dönebiliyor ve
-- engel kontrolü atlanabiliyordu. Bu yardımcı fonksiyon SECURITY DEFINER ile
-- gerçek seçili tarafları doğrudan doğrular.

create or replace function public.can_message_listing(p_listing_id bigint)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select exists (
    select 1
    from public.listings l
    join public.quotes q on q.id=l.chosen_quote and q.listing_id=l.id
    where l.id=p_listing_id
      and l.status in ('chosen','done')
      and (
        (l.owner=auth.uid() and not public.is_blocked(auth.uid(),q.pro))
        or
        (q.pro=auth.uid() and not public.is_blocked(auth.uid(),l.owner))
      )
  );
$$;

revoke all on function public.can_message_listing(bigint) from public;
grant execute on function public.can_message_listing(bigint) to authenticated;

drop policy if exists "mesaj okuma" on public.messages;
drop policy if exists "mesaj ekleme" on public.messages;

create policy "mesaj okuma" on public.messages
for select to authenticated
using (
  public.is_active_user()
  and public.can_message_listing(listing_id)
);

create policy "mesaj ekleme" on public.messages
for insert to authenticated
with check (
  public.is_active_user()
  and sender=auth.uid()
  and public.can_message_listing(listing_id)
);
