-- Tamİşim v16 — salt-okunur fotoğraf gizlilik denetimi
select
  'listing_photos SELECT policy' as kontrol,
  case when count(*)=1 and bool_and(coalesce(qual,'') not ilike '%true%') then 'OK' else 'KONTROL ET' end as sonuc
from pg_policies
where schemaname='public' and tablename='listing_photos' and cmd='SELECT'
union all
select
  'storage.objects listing-photos SELECT policy',
  case when count(*)>=1 and bool_and(coalesce(qual,'') not ilike '%bucket_id = ''listing-photos''% OR true%') then 'OK' else 'KONTROL ET' end
from pg_policies
where schemaname='storage' and tablename='objects' and cmd='SELECT' and policyname='ilan fotograflari oku';
