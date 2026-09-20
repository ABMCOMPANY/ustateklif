-- UstaTeklif veritabanı kurulumu
-- Supabase > SQL Editor > New query içine yapıştırıp bir kez "Run" de.

-- ========== TABLOLAR ==========
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'Kullanıcı',
  title text not null default 'Servis ve tamir',
  bio text not null default '',
  services text[] not null default '{}',
  service_areas text[] not null default '{}',
  service_city text not null default '',
  service_districts text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table if not exists public.listings (
  id bigint generated always as identity primary key,
  owner uuid not null references public.profiles(id) on delete cascade,
  category text not null,
  problems text[] not null,
  note text not null default '',
  area text not null,
  city text not null default '',
  district text not null default '',
  neighborhood text not null default '',
  when_text text not null default 'Bugün',
  status text not null default 'open' check (status in ('open','chosen','done')),
  chosen_quote bigint,
  rating int check (rating between 1 and 5),
  created_at timestamptz not null default now()
);

create table if not exists public.quotes (
  id bigint generated always as identity primary key,
  listing_id bigint not null references public.listings(id) on delete cascade,
  pro uuid not null references public.profiles(id) on delete cascade,
  price int not null check (price > 0),
  eta text not null,
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (listing_id, pro)
);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  listing_id bigint not null references public.listings(id) on delete cascade,
  sender uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create index if not exists listings_owner_idx on public.listings(owner);
create index if not exists listings_status_idx on public.listings(status);
create index if not exists listings_location_idx on public.listings(status, city, district);
create index if not exists quotes_listing_idx on public.quotes(listing_id);
create index if not exists quotes_pro_idx on public.quotes(pro);
create index if not exists messages_listing_idx on public.messages(listing_id);

-- ========== YENİ KULLANICI İÇİN PROFİL ==========
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'name', ''), split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ========== YARDIMCI GÖRÜNÜMLER ==========
-- Ustanın tamamlanan iş sayısı ve ortalama puanı
create or replace view public.pro_stats as
select q.pro as pro_id,
       (count(*) filter (where l.status = 'done'))::int as jobs,
       round(avg(l.rating) filter (where l.status = 'done'), 1) as rating
from public.quotes q
join public.listings l on l.chosen_quote = q.id
group by q.pro;

-- Bir ilana kaç teklif geldiği (fiyatlar gizli kalır)
create or replace view public.quote_counts as
select listing_id, count(*)::int as n
from public.quotes
group by listing_id;

-- ========== MESAJLAŞMA YETKİSİ ==========
-- Yalnızca ilan sahibi ve seçilen usta mesajlaşabilir
create or replace function public.is_party(lid bigint)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from public.listings l
    left join public.quotes q on q.id = l.chosen_quote
    where l.id = lid
      and l.status in ('chosen','done')
      and (l.owner = auth.uid() or q.pro = auth.uid())
  );
$$;

-- ========== GÜVENLİK KURALLARI (RLS) ==========
alter table public.profiles enable row level security;
alter table public.listings enable row level security;
alter table public.quotes   enable row level security;
alter table public.messages enable row level security;

drop policy if exists "profil okuma" on public.profiles;
drop policy if exists "profil ekleme" on public.profiles;
drop policy if exists "profil guncelleme" on public.profiles;
create policy "profil okuma" on public.profiles for select to authenticated using (true);
create policy "profil ekleme" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profil guncelleme" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "ilan okuma" on public.listings;
drop policy if exists "ilan ekleme" on public.listings;
drop policy if exists "ilan guncelleme" on public.listings;
drop policy if exists "ilan silme" on public.listings;
create policy "ilan okuma" on public.listings for select to authenticated using (true);
create policy "ilan ekleme" on public.listings for insert to authenticated with check (owner = auth.uid());
create policy "ilan guncelleme" on public.listings for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());
create policy "ilan silme" on public.listings for delete to authenticated using (owner = auth.uid());

drop policy if exists "teklif okuma" on public.quotes;
drop policy if exists "teklif ekleme" on public.quotes;
create policy "teklif okuma" on public.quotes for select to authenticated
  using (
    pro = auth.uid()
    or exists (select 1 from public.listings l where l.id = listing_id and l.owner = auth.uid())
  );
create policy "teklif ekleme" on public.quotes for insert to authenticated
  with check (
    pro = auth.uid()
    and exists (
      select 1 from public.listings l
      where l.id = listing_id and l.status = 'open' and l.owner <> auth.uid()
    )
  );

drop policy if exists "mesaj okuma" on public.messages;
drop policy if exists "mesaj ekleme" on public.messages;
create policy "mesaj okuma" on public.messages for select to authenticated using (public.is_party(listing_id));
create policy "mesaj ekleme" on public.messages for insert to authenticated
  with check (sender = auth.uid() and public.is_party(listing_id));



-- ========== KRİTİK İŞ AKIŞLARI ==========
-- İlan sahibi hassas alanları doğrudan güncellemez. Usta seçimi ve işi
-- tamamlama sunucu tarafındaki kontrollü fonksiyonlardan yapılır.
create or replace function public.choose_quote(p_listing_id bigint, p_quote_id bigint)
returns public.listings
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.listings;
begin
  if auth.uid() is null then
    raise exception 'Oturum gerekli';
  end if;

  update public.listings l
     set status = 'chosen', chosen_quote = p_quote_id
   where l.id = p_listing_id
     and l.owner = auth.uid()
     and l.status = 'open'
     and exists (
       select 1 from public.quotes q
        where q.id = p_quote_id
          and q.listing_id = l.id
          and q.pro <> l.owner
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
  if auth.uid() is null then
    raise exception 'Oturum gerekli';
  end if;
  if p_rating < 1 or p_rating > 5 then
    raise exception 'Puan 1 ile 5 arasında olmalı';
  end if;

  update public.listings l
     set status = 'done', rating = p_rating
   where l.id = p_listing_id
     and l.owner = auth.uid()
     and l.status = 'chosen'
     and l.chosen_quote is not null
  returning l.* into result;

  if result.id is null then
    raise exception 'İlan tamamlanmaya uygun değil';
  end if;
  return result;
end $$;

-- ========== ERİŞİM İZİNLERİ ==========
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
-- listings üzerindeki hassas durum değişiklikleri yalnızca RPC fonksiyonlarından geçer.
revoke update on public.listings from authenticated;
grant execute on function public.choose_quote(bigint, bigint) to authenticated;
grant execute on function public.complete_listing(bigint, int) to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant select on public.pro_stats, public.quote_counts to authenticated;

-- ========== ANLIK GÜNCELLEME (realtime) ==========
do $$
begin
  begin alter publication supabase_realtime add table public.listings; exception when others then null; end;
  begin alter publication supabase_realtime add table public.quotes;   exception when others then null; end;
  begin alter publication supabase_realtime add table public.messages; exception when others then null; end;
end $$;

-- ========== İLAN FOTOĞRAFLARI (v6) ==========
create table if not exists public.listing_photos (
  id bigint generated always as identity primary key,
  listing_id bigint not null references public.listings(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  path text not null unique,
  sort_order int not null default 0 check (sort_order between 0 and 4),
  created_at timestamptz not null default now()
);
create index if not exists listing_photos_listing_idx on public.listing_photos(listing_id, sort_order);
alter table public.listing_photos enable row level security;
drop policy if exists "ilan fotografi okuma" on public.listing_photos;
drop policy if exists "ilan fotografi ekleme" on public.listing_photos;
drop policy if exists "ilan fotografi silme" on public.listing_photos;
create policy "ilan fotografi okuma" on public.listing_photos for select to authenticated using (true);
create policy "ilan fotografi ekleme" on public.listing_photos for insert to authenticated
  with check (owner = auth.uid() and exists (select 1 from public.listings l where l.id=listing_id and l.owner=auth.uid()));
create policy "ilan fotografi silme" on public.listing_photos for delete to authenticated using (owner=auth.uid());
grant select, insert, delete on public.listing_photos to authenticated;
grant usage, select on all sequences in schema public to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-photos','listing-photos',false,8388608,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false, file_size_limit=8388608, allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "ilan fotograflari oku" on storage.objects;
drop policy if exists "kendi ilan fotografini yukle" on storage.objects;
drop policy if exists "kendi ilan fotografini sil" on storage.objects;
create policy "ilan fotograflari oku" on storage.objects for select to authenticated
  using (bucket_id='listing-photos');
create policy "kendi ilan fotografini yukle" on storage.objects for insert to authenticated
  with check (bucket_id='listing-photos' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "kendi ilan fotografini sil" on storage.objects for delete to authenticated
  using (bucket_id='listing-photos' and (storage.foldername(name))[1]=auth.uid()::text);

-- ========== UYGULAMA İÇİ BİLDİRİMLER (v7) ==========
-- UstaTeklif v7 - uygulama içi bildirimler
-- Mevcut Supabase projesinde SQL Editor'da bir kez çalıştırın.

create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('quote','chosen','message','nearby_job')),
  title text not null,
  body text not null default '',
  listing_id bigint references public.listings(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications(user_id, read_at) where read_at is null;
alter table public.notifications enable row level security;
drop policy if exists "bildirim okuma" on public.notifications;
drop policy if exists "bildirim guncelleme" on public.notifications;
create policy "bildirim okuma" on public.notifications for select to authenticated using (user_id=auth.uid());
create policy "bildirim guncelleme" on public.notifications for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
revoke insert, delete on public.notifications from authenticated;
grant select, update on public.notifications to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Yeni teklif -> ilan sahibine bildirim
create or replace function public.notify_new_quote() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_owner uuid; v_name text;
begin
  select owner into v_owner from public.listings where id=new.listing_id;
  select name into v_name from public.profiles where id=new.pro;
  if v_owner is not null then
    insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
    values(v_owner,'quote','Yeni teklif geldi',coalesce(v_name,'Bir usta')||' ilanına teklif verdi.',new.listing_id,new.pro);
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_new_quote on public.quotes;
create trigger trg_notify_new_quote after insert on public.quotes for each row execute function public.notify_new_quote();

-- Mesaj -> konuşmadaki diğer tarafa bildirim
create or replace function public.notify_new_message() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_owner uuid; v_pro uuid; v_to uuid; v_name text;
begin
  select l.owner,q.pro into v_owner,v_pro from public.listings l left join public.quotes q on q.id=l.chosen_quote where l.id=new.listing_id;
  v_to:=case when new.sender=v_owner then v_pro else v_owner end;
  select name into v_name from public.profiles where id=new.sender;
  if v_to is not null and v_to<>new.sender then
    insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
    values(v_to,'message','Yeni mesaj',coalesce(v_name,'Bir kullanıcı')||' sana mesaj gönderdi.',new.listing_id,new.sender);
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_new_message on public.messages;
create trigger trg_notify_new_message after insert on public.messages for each row execute function public.notify_new_message();

-- Yeni ilan -> profilinde hizmet bölgesi tanımlayan uygun ustalara bildirim.
-- service_districts boşsa usta tüm şehirde hizmet veriyor kabul edilir.
create or replace function public.notify_nearby_job() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  select p.id,'nearby_job','Bölgende yeni iş',
         coalesce(array_to_string(new.problems, ', '),'Yeni hizmet talebi')||' · '||coalesce(new.district,new.city),
         new.id,new.owner
  from public.profiles p
  where p.id<>new.owner
    and coalesce(p.service_city,'')<>''
    and lower(trim(p.service_city))=lower(trim(new.city))
    and (coalesce(array_length(p.service_districts,1),0)=0 or exists(select 1 from unnest(p.service_districts) d where lower(trim(d))=lower(trim(new.district))))
    and coalesce(array_length(p.services,1),0)>0;
  return new;
end $$;
drop trigger if exists trg_notify_nearby_job on public.listings;
create trigger trg_notify_nearby_job after insert on public.listings for each row execute function public.notify_nearby_job();

-- Usta seçildi bildirimi choose_quote RPC'sine güvenli biçimde eklenir.
create or replace function public.choose_quote(p_listing_id bigint, p_quote_id bigint)
returns public.listings
language plpgsql security definer set search_path=public as $$
declare result public.listings; v_pro uuid;
begin
  if auth.uid() is null then raise exception 'Oturum gerekli'; end if;
  update public.listings l set status='chosen',chosen_quote=p_quote_id
   where l.id=p_listing_id and l.owner=auth.uid() and l.status='open'
     and exists(select 1 from public.quotes q where q.id=p_quote_id and q.listing_id=l.id and q.pro<>l.owner)
  returning l.* into result;
  if result.id is null then raise exception 'İlan açık değil, sana ait değil veya teklif bu ilana ait değil'; end if;
  select pro into v_pro from public.quotes where id=p_quote_id and listing_id=p_listing_id;
  if v_pro is not null then
    insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
    values(v_pro,'chosen','Teklifin seçildi','Müşteri teklifini seçti. Artık mesajlaşabilirsiniz.',p_listing_id,auth.uid());
  end if;
  return result;
end $$;
grant execute on function public.choose_quote(bigint,bigint) to authenticated;

do $$ begin
  begin alter publication supabase_realtime add table public.notifications; exception when others then null; end;
end $$;
-- UstaTeklif v8 — güven, doğrulama, şikâyet ve engelleme
-- Mevcut v7 Supabase projesinde SQL Editor'da bir kez çalıştırın.

alter table public.profiles add column if not exists phone_verified boolean not null default false;
alter table public.profiles add column if not exists identity_verified boolean not null default false;

-- Doğrulama alanları istemciden değiştirilemez. Profilin yalnızca kullanıcı tarafından
-- düzenlenebilir alanlarına kolon seviyesinde UPDATE izni verilir.
revoke update on public.profiles from authenticated;
grant update (name,title,bio,services,service_areas,service_city,service_districts) on public.profiles to authenticated;

create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists user_blocks_blocked_idx on public.user_blocks(blocked_id);
alter table public.user_blocks enable row level security;
drop policy if exists "engellerimi oku" on public.user_blocks;
drop policy if exists "kullanici engelle" on public.user_blocks;
drop policy if exists "engeli kaldir" on public.user_blocks;
create policy "engellerimi oku" on public.user_blocks for select to authenticated using (blocker_id=auth.uid());
create policy "kullanici engelle" on public.user_blocks for insert to authenticated with check (blocker_id=auth.uid() and blocked_id<>auth.uid());
create policy "engeli kaldir" on public.user_blocks for delete to authenticated using (blocker_id=auth.uid());
grant select,insert,delete on public.user_blocks to authenticated;

create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid not null references public.profiles(id) on delete cascade,
  listing_id bigint references public.listings(id) on delete set null,
  reason text not null check (char_length(reason) between 10 and 500),
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now(),
  check (reporter_id <> reported_id)
);
create index if not exists reports_status_idx on public.reports(status,created_at desc);
alter table public.reports enable row level security;
drop policy if exists "sikayet olustur" on public.reports;
create policy "sikayet olustur" on public.reports for insert to authenticated with check (reporter_id=auth.uid() and reported_id<>auth.uid());
-- Şikâyet kayıtları uygulama kullanıcılarına listelenmez; yönetim/service-role tarafında incelenir.
revoke select,update,delete on public.reports from authenticated;
grant insert on public.reports to authenticated;
grant usage,select on all sequences in schema public to authenticated;

-- İki kullanıcıdan biri diğerini engellediyse true.
create or replace function public.is_blocked(a uuid,b uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from public.user_blocks x where (x.blocker_id=a and x.blocked_id=b) or (x.blocker_id=b and x.blocked_id=a));
$$;
revoke all on function public.is_blocked(uuid,uuid) from public;
grant execute on function public.is_blocked(uuid,uuid) to authenticated;

-- Telefon rozeti auth.users içindeki gerçek phone_confirmed_at alanından türetilir.
create or replace function public.sync_my_verification()
returns public.profiles language plpgsql security definer set search_path=public,auth as $$
declare r public.profiles;
begin
  if auth.uid() is null then raise exception 'Oturum gerekli'; end if;
  update public.profiles p
     set phone_verified = exists(select 1 from auth.users u where u.id=auth.uid() and u.phone_confirmed_at is not null)
   where p.id=auth.uid()
  returning p.* into r;
  return r;
end $$;
revoke all on function public.sync_my_verification() from public;
grant execute on function public.sync_my_verification() to authenticated;

-- Engellenen kullanıcılar arasında yeni ilan/teklif/mesaj etkileşimini kes.
drop policy if exists "ilan okuma" on public.listings;
create policy "ilan okuma" on public.listings for select to authenticated
  using (owner=auth.uid() or not public.is_blocked(auth.uid(),owner));

drop policy if exists "teklif okuma" on public.quotes;
create policy "teklif okuma" on public.quotes for select to authenticated using (
  (pro=auth.uid() and not public.is_blocked(auth.uid(),(select owner from public.listings l where l.id=listing_id)))
  or exists(select 1 from public.listings l where l.id=listing_id and l.owner=auth.uid() and not public.is_blocked(auth.uid(),pro))
);
drop policy if exists "teklif ekleme" on public.quotes;
create policy "teklif ekleme" on public.quotes for insert to authenticated with check (
  pro=auth.uid() and exists(select 1 from public.listings l where l.id=listing_id and l.status='open' and l.owner<>auth.uid() and not public.is_blocked(auth.uid(),l.owner))
);

drop policy if exists "mesaj okuma" on public.messages;
drop policy if exists "mesaj ekleme" on public.messages;
create policy "mesaj okuma" on public.messages for select to authenticated using (
  public.is_party(listing_id) and not public.is_blocked(auth.uid(),sender)
);
create policy "mesaj ekleme" on public.messages for insert to authenticated with check (
  sender=auth.uid() and public.is_party(listing_id) and not public.is_blocked(auth.uid(),
    (select case when l.owner=auth.uid() then q.pro else l.owner end from public.listings l left join public.quotes q on q.id=l.chosen_quote where l.id=listing_id)
  )
);
-- UstaTeklif v9 — yönetici paneli ve moderasyon
-- Mevcut v8 projede Supabase SQL Editor'da bir kez çalıştırın.

alter table public.profiles add column if not exists account_status text not null default 'active'
  check (account_status in ('active','suspended'));

create table if not exists public.admin_users (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admin_users enable row level security;
revoke all on public.admin_users from anon, authenticated;

create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path=public as $$
  select auth.uid() is not null and exists(select 1 from public.admin_users a where a.user_id=auth.uid());
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

create or replace function public.is_active_user()
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from public.profiles p where p.id=auth.uid() and p.account_status='active');
$$;
revoke all on function public.is_active_user() from public;
grant execute on function public.is_active_user() to authenticated;

-- Doğrulama/durum alanları yalnızca güvenilir yönetim RPC'sinden değişir.
revoke update on public.profiles from authenticated;
grant update (name,title,bio,services,service_areas,service_city,service_districts) on public.profiles to authenticated;

-- Yönetici şikâyetleri okuyup durumunu değiştirebilir.
drop policy if exists "yonetici sikayet okuma" on public.reports;
drop policy if exists "yonetici sikayet guncelleme" on public.reports;
create policy "yonetici sikayet okuma" on public.reports for select to authenticated using (public.is_admin());
create policy "yonetici sikayet guncelleme" on public.reports for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant select,update on public.reports to authenticated;

create or replace function public.admin_dashboard()
returns jsonb language sql security definer stable set search_path=public as $$
  select case when public.is_admin() then jsonb_build_object(
    'users',(select count(*) from public.profiles),
    'suspended',(select count(*) from public.profiles where account_status='suspended'),
    'open_reports',(select count(*) from public.reports where status in ('open','reviewing')),
    'open_listings',(select count(*) from public.listings where status='open'),
    'done_listings',(select count(*) from public.listings where status='done')
  ) else null end;
$$;
revoke all on function public.admin_dashboard() from public;
grant execute on function public.admin_dashboard() to authenticated;

create or replace function public.admin_set_identity(p_user_id uuid,p_verified boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Yetkisiz'; end if;
  update public.profiles set identity_verified=p_verified where id=p_user_id;
end $$;
revoke all on function public.admin_set_identity(uuid,boolean) from public;
grant execute on function public.admin_set_identity(uuid,boolean) to authenticated;

create or replace function public.admin_set_account_status(p_user_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Yetkisiz'; end if;
  if p_status not in ('active','suspended') then raise exception 'Geçersiz durum'; end if;
  if p_user_id=auth.uid() and p_status='suspended' then raise exception 'Kendi hesabını askıya alamazsın'; end if;
  update public.profiles set account_status=p_status where id=p_user_id;
end $$;
revoke all on function public.admin_set_account_status(uuid,text) from public;
grant execute on function public.admin_set_account_status(uuid,text) to authenticated;

-- İlk yöneticiyi eklemek için SQL Editor'da, kayıtlı kullanıcının e-postasını değiştirerek bir kez çalıştırın:
-- insert into public.admin_users(user_id)
-- select id from auth.users where email='SENIN-EMAILIN@example.com'
-- on conflict do nothing;
