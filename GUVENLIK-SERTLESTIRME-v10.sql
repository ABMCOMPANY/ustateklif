-- Tamİşim v10 — kritik RLS / yetki sertleştirmesi
-- v9 kurulumu yapılmış projede bir kez çalıştırın.

-- Askıdaki hesap yeni ilan/teklif/mesaj/şikâyet/engel/fotoğraf oluşturamaz.
drop policy if exists "ilan ekleme" on public.listings;
create policy "ilan ekleme" on public.listings for insert to authenticated
with check (owner=auth.uid() and public.is_active_user());

drop policy if exists "ilan silme" on public.listings;
create policy "ilan silme" on public.listings for delete to authenticated
using (owner=auth.uid() and public.is_active_user());

drop policy if exists "teklif ekleme" on public.quotes;
create policy "teklif ekleme" on public.quotes for insert to authenticated
with check (
  public.is_active_user() and pro=auth.uid()
  and exists (
    select 1 from public.listings l
    where l.id=listing_id and l.status='open' and l.owner<>auth.uid()
      and not public.is_blocked(auth.uid(),l.owner)
  )
);

drop policy if exists "mesaj ekleme" on public.messages;
create policy "mesaj ekleme" on public.messages for insert to authenticated
with check (
  public.is_active_user() and sender=auth.uid() and public.is_party(listing_id)
  and not public.is_blocked(auth.uid(),
    (select case when l.owner=auth.uid() then q.pro else l.owner end
     from public.listings l left join public.quotes q on q.id=l.chosen_quote
     where l.id=listing_id)
  )
);

drop policy if exists "kullanici engelle" on public.user_blocks;
create policy "kullanici engelle" on public.user_blocks for insert to authenticated
with check (public.is_active_user() and blocker_id=auth.uid() and blocked_id<>auth.uid());

drop policy if exists "sikayet olustur" on public.reports;
create policy "sikayet olustur" on public.reports for insert to authenticated
with check (public.is_active_user() and reporter_id=auth.uid() and reported_id<>auth.uid());

-- Fotoğraf metadata'sı yalnızca kullanıcının açık ilanına eklenebilir.
drop policy if exists "ilan fotografi ekleme" on public.listing_photos;
create policy "ilan fotografi ekleme" on public.listing_photos for insert to authenticated
with check (
  public.is_active_user() and owner=auth.uid()
  and exists (
    select 1 from public.listings l
    where l.id=listing_id and l.owner=auth.uid() and l.status='open'
  )
);

-- Storage yolu: <uid>/<listing_id>/<dosya>. Kullanıcı başka ilana nesne yükleyemez.
drop policy if exists "kendi ilan fotografini yukle" on storage.objects;
create policy "kendi ilan fotografini yukle" on storage.objects for insert to authenticated
with check (
  bucket_id='listing-photos'
  and public.is_active_user()
  and (storage.foldername(name))[1]=auth.uid()::text
  and (storage.foldername(name))[2] ~ '^[0-9]+$'
  and exists (
    select 1 from public.listings l
    where l.id=((storage.foldername(name))[2])::bigint
      and l.owner=auth.uid() and l.status='open'
  )
);

-- Kritik RPC'ler askı ve engellemeyi sunucu tarafında da zorunlu kılar.
create or replace function public.choose_quote(p_listing_id bigint,p_quote_id bigint)
returns public.listings
language plpgsql security definer set search_path=public as $$
declare result public.listings; v_pro uuid;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  select q.pro into v_pro from public.quotes q
  where q.id=p_quote_id and q.listing_id=p_listing_id;

  if v_pro is null or public.is_blocked(auth.uid(),v_pro) then
    raise exception 'Bu teklif seçilemez';
  end if;

  update public.listings l
  set status='chosen',chosen_quote=p_quote_id
  where l.id=p_listing_id and l.owner=auth.uid() and l.status='open'
    and exists (
      select 1 from public.quotes q
      where q.id=p_quote_id and q.listing_id=l.id and q.pro<>l.owner
    )
  returning l.* into result;

  if result.id is null then
    raise exception 'İlan açık değil, sana ait değil veya teklif bu ilana ait değil';
  end if;

  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(v_pro,'chosen','Teklifin seçildi','Müşteri teklifini seçti. Artık mesajlaşabilirsiniz.',p_listing_id,auth.uid());

  return result;
end $$;

create or replace function public.complete_listing(p_listing_id bigint,p_rating int)
returns public.listings
language plpgsql security definer set search_path=public as $$
declare result public.listings;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;
  if p_rating < 1 or p_rating > 5 then
    raise exception 'Puan 1 ile 5 arasında olmalı';
  end if;

  update public.listings l set status='done',rating=p_rating
  where l.id=p_listing_id and l.owner=auth.uid()
    and l.status='chosen' and l.chosen_quote is not null
  returning l.* into result;

  if result.id is null then raise exception 'İlan tamamlanmaya uygun değil'; end if;
  return result;
end $$;

-- Profil doğrulama/durum kolonları kullanıcı tarafından değiştirilemez.
drop policy if exists "profil guncelleme" on public.profiles;
create policy "profil guncelleme" on public.profiles for update to authenticated
using (id=auth.uid() and account_status='active')
with check (id=auth.uid() and account_status='active');

revoke update on public.profiles from authenticated;
grant update (name,title,bio,services,service_areas,service_city,service_districts) on public.profiles to authenticated;

-- SECURITY DEFINER fonksiyonlarını PUBLIC/anon çalıştıramaz.
revoke all on function public.choose_quote(bigint,bigint) from public;
revoke all on function public.complete_listing(bigint,int) from public;
revoke all on function public.sync_my_verification() from public;
revoke all on function public.is_admin() from public;
revoke all on function public.is_active_user() from public;
revoke all on function public.is_blocked(uuid,uuid) from public;

grant execute on function public.choose_quote(bigint,bigint) to authenticated;
grant execute on function public.complete_listing(bigint,int) to authenticated;
grant execute on function public.sync_my_verification() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_active_user() to authenticated;
grant execute on function public.is_blocked(uuid,uuid) to authenticated;
