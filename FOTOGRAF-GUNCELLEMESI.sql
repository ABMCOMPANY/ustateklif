-- UstaTeklif v6 - mevcut projeye ilan fotoğrafları ekler.
-- Supabase > SQL Editor içinde bir kez çalıştır.
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
create policy "ilan fotograflari oku" on storage.objects for select to authenticated using (bucket_id='listing-photos');
create policy "kendi ilan fotografini yukle" on storage.objects for insert to authenticated
  with check (bucket_id='listing-photos' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "kendi ilan fotografini sil" on storage.objects for delete to authenticated
  using (bucket_id='listing-photos' and (storage.foldername(name))[1]=auth.uid()::text);
