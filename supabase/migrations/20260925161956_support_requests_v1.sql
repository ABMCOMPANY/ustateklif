
begin;

create table if not exists public.support_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null default 'general' check (category in ('general','payment','account','safety','technical','partner')),
  subject text not null check (char_length(subject) between 3 and 120),
  message text not null check (char_length(message) between 10 and 2000),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  admin_response text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists support_requests_user_idx on public.support_requests(user_id,created_at desc);
create index if not exists support_requests_status_idx on public.support_requests(status,created_at desc);

alter table public.support_requests enable row level security;
grant select,insert on public.support_requests to authenticated;
revoke update,delete on public.support_requests from authenticated;
revoke all on public.support_requests from anon;

drop policy if exists support_requests_read_own_or_admin on public.support_requests;
create policy support_requests_read_own_or_admin
on public.support_requests for select to authenticated
using (user_id=(select auth.uid()) or public.is_admin());

drop policy if exists support_requests_insert_own on public.support_requests;
create policy support_requests_insert_own
on public.support_requests for insert to authenticated
with check (
  user_id=(select auth.uid())
  and status='open'
  and public.is_active_user()
);

create or replace function public.admin_update_support_request(
  p_request_id uuid,
  p_status text,
  p_response text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Yetkisiz işlem'; end if;
  if p_status not in ('open','in_progress','resolved','closed') then
    raise exception 'Geçersiz durum';
  end if;
  update public.support_requests
  set status=p_status,
      admin_response=nullif(trim(coalesce(p_response,'')),''),
      updated_at=now(),
      resolved_at=case when p_status in ('resolved','closed') then coalesce(resolved_at,now()) else null end
  where id=p_request_id;
  if not found then raise exception 'Destek talebi bulunamadı'; end if;
end;
$$;

revoke all on function public.admin_update_support_request(uuid,text,text) from public,anon;
grant execute on function public.admin_update_support_request(uuid,text,text) to authenticated;

commit;
