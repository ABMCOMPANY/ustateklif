-- UstaTeklif mevcut kurulumlar için güvenlik güncellemesi
-- Supabase > SQL Editor > New query içine yapıştır ve bir kez Run de.

create or replace function public.choose_quote(p_listing_id bigint, p_quote_id bigint)
returns public.listings
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.listings;
begin
  if auth.uid() is null then raise exception 'Oturum gerekli'; end if;

  update public.listings l
     set status = 'chosen', chosen_quote = p_quote_id
   where l.id = p_listing_id
     and l.owner = auth.uid()
     and l.status = 'open'
     and exists (
       select 1 from public.quotes q
       where q.id = p_quote_id and q.listing_id = l.id and q.pro <> l.owner
     )
  returning l.* into result;

  if result.id is null then
    raise exception 'İlan açık değil, sana ait değil veya teklif bu ilana ait değil';
  end if;
  return result;
end $$;

create or replace function public.complete_listing(p_listing_id bigint, p_rating int)
returns public.listings
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.listings;
begin
  if auth.uid() is null then raise exception 'Oturum gerekli'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'Puan 1 ile 5 arasında olmalı'; end if;

  update public.listings l
     set status = 'done', rating = p_rating
   where l.id = p_listing_id
     and l.owner = auth.uid()
     and l.status = 'chosen'
     and l.chosen_quote is not null
  returning l.* into result;

  if result.id is null then raise exception 'İlan tamamlanmaya uygun değil'; end if;
  return result;
end $$;

-- İstemci artık listings tablosunun hassas alanlarını doğrudan değiştiremez.
revoke update on public.listings from authenticated;
grant execute on function public.choose_quote(bigint, bigint) to authenticated;
grant execute on function public.complete_listing(bigint, int) to authenticated;
