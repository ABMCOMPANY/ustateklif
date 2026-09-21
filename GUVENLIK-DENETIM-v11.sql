-- Tamİşim v11 — salt-okunur kritik INSERT denetimi
-- Veri değiştirmez.

with checks(test,sonuc,detay) as (
  select
    'PROFILES TABLE INSERT',
    case when has_table_privilege('authenticated','public.profiles','INSERT')
      then 'KRITIK' else 'OK' end,
    'Profil auth.users tetikleyicisiyle oluşmalı; istemci doğrudan INSERT yapmamalı'

  union all
  select
    'PROFILE INSERT: identity_verified',
    case when has_column_privilege('authenticated','public.profiles','identity_verified','INSERT')
      then 'KRITIK' else 'OK' end,
    'Kimlik doğrulaması kullanıcı tarafından oluşturulamamalı'

  union all
  select
    'PROFILE INSERT: phone_verified',
    case when has_column_privilege('authenticated','public.profiles','phone_verified','INSERT')
      then 'KRITIK' else 'OK' end,
    'Telefon doğrulaması kullanıcı tarafından oluşturulamamalı'

  union all
  select
    'PROFILE INSERT: account_status',
    case when has_column_privilege('authenticated','public.profiles','account_status','INSERT')
      then 'KRITIK' else 'OK' end,
    'Hesap durumu kullanıcı tarafından oluşturulamamalı'

  union all
  select
    'LISTING INSERT: status',
    case when has_column_privilege('authenticated','public.listings','status','INSERT')
      then 'KRITIK' else 'OK' end,
    'Yeni ilan status alanını istemci yazmamalı'

  union all
  select
    'LISTING INSERT: chosen_quote',
    case when has_column_privilege('authenticated','public.listings','chosen_quote','INSERT')
      then 'KRITIK' else 'OK' end,
    'Yeni ilan seçilmiş teklif ile oluşturulamamalı'

  union all
  select
    'LISTING INSERT: rating',
    case when has_column_privilege('authenticated','public.listings','rating','INSERT')
      then 'KRITIK' else 'OK' end,
    'Yeni ilan puan ile oluşturulamamalı'
)
select * from checks
order by case sonuc when 'KRITIK' then 0 else 1 end, test;
