-- Tamİşim v17 — fotoğraf erişimi için sunucu tarafı yetki yardımcısı
-- Test ve uygulama aynı yetki kararını kullanabilsin diye eklenir.

create or replace function public.can_view_listing_photo(p_listing_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.listings l
    where l.id = p_listing_id
      and public.is_active_user()
      and (
        l.owner = auth.uid()
        or (
          l.status = 'open'
          and l.owner <> auth.uid()
          and not public.is_blocked(l.owner, auth.uid())
        )
        or public.is_party(l.id)
      )
  );
$$;

revoke all on function public.can_view_listing_photo(bigint) from public;
grant execute on function public.can_view_listing_photo(bigint) to authenticated;
