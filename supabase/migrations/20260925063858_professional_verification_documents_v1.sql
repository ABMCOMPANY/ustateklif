begin;

alter table public.profiles
  add column if not exists vocational_verified boolean not null default false,
  add column if not exists business_verified boolean not null default false;

create table if not exists public.professional_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null default 'general',
  verification_type text not null
    check (verification_type in ('identity','vocational','diploma','certificate','business')),
  document_type text not null,
  storage_path text not null unique,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','expired')),
  review_note text,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists professional_verifications_user_idx
  on public.professional_verifications(user_id);
create index if not exists professional_verifications_status_idx
  on public.professional_verifications(status,created_at);

alter table public.professional_verifications enable row level security;
grant select, insert on public.professional_verifications to authenticated;
revoke update, delete on public.professional_verifications from authenticated;
revoke all on public.professional_verifications from anon;

drop policy if exists professional_verifications_read_own on public.professional_verifications;
create policy professional_verifications_read_own
on public.professional_verifications for select to authenticated
using (user_id=(select auth.uid()) or public.is_admin());

drop policy if exists professional_verifications_insert_own_pending on public.professional_verifications;
create policy professional_verifications_insert_own_pending
on public.professional_verifications for insert to authenticated
with check (
  user_id=(select auth.uid())
  and status='pending'
  and reviewed_at is null
  and reviewed_by is null
);

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'verification-docs',
  'verification-docs',
  false,
  8388608,
  array['image/jpeg','image/png','image/webp','application/pdf']::text[]
)
on conflict (id) do update
set public=false,
    file_size_limit=8388608,
    allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf']::text[];

drop policy if exists verification_docs_upload_own on storage.objects;
create policy verification_docs_upload_own
on storage.objects for insert to authenticated
with check (
  bucket_id='verification-docs'
  and (storage.foldername(name))[1]=(select auth.uid())::text
);

drop policy if exists verification_docs_read_own_or_admin on storage.objects;
create policy verification_docs_read_own_or_admin
on storage.objects for select to authenticated
using (
  bucket_id='verification-docs'
  and (
    (storage.foldername(name))[1]=(select auth.uid())::text
    or public.is_admin()
  )
);

drop policy if exists verification_docs_delete_own_pending on storage.objects;
create policy verification_docs_delete_own_pending
on storage.objects for delete to authenticated
using (
  bucket_id='verification-docs'
  and (storage.foldername(name))[1]=(select auth.uid())::text
  and exists (
    select 1 from public.professional_verifications v
    where v.storage_path=name
      and v.user_id=(select auth.uid())
      and v.status='pending'
  )
);

create or replace function public.admin_review_verification(
  p_verification_id uuid,
  p_status text,
  p_note text default null
)
returns public.professional_verifications
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.professional_verifications;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Yetkisiz';
  end if;
  if p_status not in ('approved','rejected','expired') then
    raise exception 'Geçersiz durum';
  end if;

  update public.professional_verifications
  set status=p_status,
      review_note=nullif(trim(coalesce(p_note,'')),''),
      reviewed_at=now(),
      reviewed_by=auth.uid()
  where id=p_verification_id and status='pending'
  returning * into v;

  if v.id is null then raise exception 'Bekleyen doğrulama bulunamadı'; end if;

  if v.verification_type='identity' then
    update public.profiles
    set identity_verified = exists(
      select 1 from public.professional_verifications x
      where x.user_id=v.user_id and x.verification_type='identity' and x.status='approved'
    )
    where id=v.user_id;
  end if;

  if v.verification_type in ('vocational','diploma','certificate') then
    update public.profiles
    set vocational_verified = exists(
      select 1 from public.professional_verifications x
      where x.user_id=v.user_id
        and x.verification_type in ('vocational','diploma','certificate')
        and x.status='approved'
    )
    where id=v.user_id;
  end if;

  if v.verification_type='business' then
    update public.profiles
    set business_verified = exists(
      select 1 from public.professional_verifications x
      where x.user_id=v.user_id and x.verification_type='business' and x.status='approved'
    )
    where id=v.user_id;
  end if;

  return v;
end;
$$;

revoke all on function public.admin_review_verification(uuid,text,text) from public, anon;
grant execute on function public.admin_review_verification(uuid,text,text) to authenticated;

commit;
