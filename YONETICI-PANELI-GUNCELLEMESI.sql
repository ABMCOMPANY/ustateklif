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
