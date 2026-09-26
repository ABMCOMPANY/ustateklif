
create or replace function public.admin_upsert_partner_with_categories(
  p_name text,
  p_slug text,
  p_status text default 'active',
  p_service_categories text[] default null
)
returns public.partners
language plpgsql
security definer
set search_path='public'
as $$
declare
  v public.partners%rowtype;
  allowed constant text[] := array[
    'boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi','elektronik',
    'lastik','oto','temizlik','nakliyat','bahce','ozelders','guzellik','kucukisler',
    'evcilhayvan','diger'
  ]::text[];
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Yetkisiz';
  end if;
  if length(trim(coalesce(p_name,''))) < 2 then
    raise exception 'Partner adı gerekli';
  end if;
  if trim(coalesce(p_slug,'')) !~ '^[a-z0-9-]{2,50}$' then
    raise exception 'Partner kısa adı geçersiz';
  end if;
  if p_status not in ('active','paused','disabled') then
    raise exception 'Geçersiz durum';
  end if;
  if p_service_categories is not null then
    if cardinality(p_service_categories) < 1 or cardinality(p_service_categories) > 19 then
      raise exception 'En az 1 hizmet alanı seçilmeli';
    end if;
    if not (p_service_categories <@ allowed) then
      raise exception 'Geçersiz hizmet alanı';
    end if;
  end if;

  insert into public.partners(name,slug,status,service_categories)
  values(
    trim(p_name),
    lower(trim(p_slug)),
    p_status,
    case when p_service_categories is null then null
         else array(select distinct x from unnest(p_service_categories) x)
    end
  )
  on conflict (slug) do update
    set name=excluded.name,
        status=excluded.status,
        service_categories=excluded.service_categories
  returning * into v;

  return v;
end;
$$;

revoke all on function public.admin_upsert_partner_with_categories(text,text,text,text[]) from public;
grant execute on function public.admin_upsert_partner_with_categories(text,text,text,text[]) to authenticated;

