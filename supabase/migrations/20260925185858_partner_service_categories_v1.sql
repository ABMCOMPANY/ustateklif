
alter table public.partners
  add column if not exists service_categories text[];

alter table public.partners
  drop constraint if exists partners_service_categories_check;

alter table public.partners
  add constraint partners_service_categories_check
  check (
    service_categories is null
    or (
      cardinality(service_categories) between 1 and 19
      and service_categories <@ array[
        'boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi','elektronik',
        'lastik','oto','temizlik','nakliyat','bahce','ozelders','guzellik','kucukisler',
        'evcilhayvan','diger'
      ]::text[]
    )
  );

create or replace function public.admin_set_partner_categories(
  p_partner_id uuid,
  p_service_categories text[]
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

  if p_service_categories is not null then
    if cardinality(p_service_categories) < 1 or cardinality(p_service_categories) > 19 then
      raise exception 'En az 1 hizmet alanı seçilmeli';
    end if;
    if not (p_service_categories <@ allowed) then
      raise exception 'Geçersiz hizmet alanı';
    end if;
  end if;

  update public.partners
  set service_categories = case
    when p_service_categories is null then null
    else array(select distinct x from unnest(p_service_categories) x)
  end
  where id=p_partner_id
  returning * into v;

  if v.id is null then raise exception 'Partner bulunamadı'; end if;
  return v;
end;
$$;

revoke all on function public.admin_set_partner_categories(uuid,text[]) from public;
grant execute on function public.admin_set_partner_categories(uuid,text[]) to authenticated;

