-- Tamİşim v10 — salt-okunur güvenlik denetimi
-- Bu sorgu veri eklemez, güncellemez veya silmez.
-- Supabase SQL Editor'da çalıştırılabilir.

with checks as (
  select
    'RLS: '||c.relname as test,
    case when c.relrowsecurity then 'OK' else 'KRITIK' end as sonuc,
    'row_level_security' as detay
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in ('profiles','listings','quotes','messages','listing_photos','notifications','user_blocks','reports','admin_users')

  union all

  select
    'POLICY: '||tablename||' / '||policyname,
    'OK',
    cmd
  from pg_policies
  where schemaname='public'
    and tablename in ('profiles','listings','quotes','messages','listing_photos','notifications','user_blocks','reports','admin_users')

  union all

  select
    'FUNCTION PUBLIC EXECUTE: '||p.proname,
    case when has_function_privilege('public',p.oid,'EXECUTE') then 'KRITIK' else 'OK' end,
    'PUBLIC rolü kritik fonksiyonu çalıştırmamalı'
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname in ('choose_quote','complete_listing','sync_my_verification','is_admin','is_active_user','is_blocked','admin_dashboard','admin_set_identity','admin_set_account_status')

  union all

  select
    'PROFILE COLUMN UPDATE: '||a.attname,
    case
      when a.attname in ('identity_verified','phone_verified','account_status')
        and has_column_privilege('authenticated','public.profiles',a.attname,'UPDATE') then 'KRITIK'
      when a.attname in ('identity_verified','phone_verified','account_status') then 'OK'
      else 'BILGI'
    end,
    'authenticated UPDATE yetkisi'
  from pg_attribute a
  where a.attrelid='public.profiles'::regclass
    and a.attnum>0 and not a.attisdropped
    and a.attname in ('identity_verified','phone_verified','account_status')

  union all

  select
    'DIRECT LISTINGS UPDATE',
    case when has_table_privilege('authenticated','public.listings','UPDATE') then 'KRITIK' else 'OK' end,
    'Durum/chosen_quote/rating yalnız RPC ile değişmeli'

  union all

  select
    'NOTIFICATIONS INSERT',
    case when has_table_privilege('authenticated','public.notifications','INSERT') then 'KRITIK' else 'OK' end,
    'Bildirimleri normal kullanıcı üretememeli'

  union all

  select
    'ADMIN_USERS ACCESS',
    case when has_table_privilege('authenticated','public.admin_users','SELECT')
           or has_table_privilege('authenticated','public.admin_users','INSERT')
           or has_table_privilege('authenticated','public.admin_users','UPDATE')
           or has_table_privilege('authenticated','public.admin_users','DELETE')
         then 'KRITIK' else 'OK' end,
    'Admin üyeliği normal kullanıcıdan kapalı olmalı'
)
select * from checks
order by case sonuc when 'KRITIK' then 0 when 'OK' then 1 else 2 end, test;
