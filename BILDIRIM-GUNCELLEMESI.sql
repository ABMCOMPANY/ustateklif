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
