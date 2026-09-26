begin;

create table if not exists public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  reason text,
  status text not null default 'pending' check (status in ('pending','processing','completed','rejected')),
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id,status)
);

alter table public.account_deletion_requests enable row level security;
grant select,insert on public.account_deletion_requests to authenticated;
revoke update,delete on public.account_deletion_requests from authenticated;
revoke all on public.account_deletion_requests from anon;

drop policy if exists deletion_request_read_own_or_admin on public.account_deletion_requests;
create policy deletion_request_read_own_or_admin
on public.account_deletion_requests for select to authenticated
using (user_id=(select auth.uid()) or public.is_admin());

drop policy if exists deletion_request_insert_own on public.account_deletion_requests;
create policy deletion_request_insert_own
on public.account_deletion_requests for insert to authenticated
with check (
  user_id=(select auth.uid())
  and status='pending'
  and public.is_active_user()
);

create or replace function public.admin_set_deletion_request_status(
  p_request_id uuid,
  p_status text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Yetkisiz işlem'; end if;
  if p_status not in ('pending','processing','completed','rejected') then
    raise exception 'Geçersiz durum';
  end if;
  update public.account_deletion_requests
  set status=p_status, admin_note=nullif(trim(coalesce(p_note,'')),''), updated_at=now()
  where id=p_request_id;
  if not found then raise exception 'Talep bulunamadı'; end if;
end;
$$;

revoke all on function public.admin_set_deletion_request_status(uuid,text,text) from public,anon;
grant execute on function public.admin_set_deletion_request_status(uuid,text,text) to authenticated;

commit;
