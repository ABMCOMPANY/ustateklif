begin;

create or replace function public.admin_upsert_partner(
  p_name text,
  p_slug text,
  p_status text default 'active'
)
returns public.partners
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.partners%rowtype;
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

  insert into public.partners(name,slug,status)
  values(trim(p_name),lower(trim(p_slug)),p_status)
  on conflict (slug) do update
    set name=excluded.name,
        status=excluded.status
  returning * into v;

  return v;
end;
$$;

revoke all on function public.admin_upsert_partner(text,text,text) from public, anon;
grant execute on function public.admin_upsert_partner(text,text,text) to authenticated;

create or replace function public.admin_set_partner_status(
  p_partner_id uuid,
  p_status text
)
returns public.partners
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.partners%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Yetkisiz';
  end if;
  if p_status not in ('active','paused','disabled') then
    raise exception 'Geçersiz durum';
  end if;

  update public.partners
  set status=p_status
  where id=p_partner_id
  returning * into v;

  if v.id is null then raise exception 'Partner bulunamadı'; end if;
  return v;
end;
$$;

revoke all on function public.admin_set_partner_status(uuid,text) from public, anon;
grant execute on function public.admin_set_partner_status(uuid,text) to authenticated;

commit;
