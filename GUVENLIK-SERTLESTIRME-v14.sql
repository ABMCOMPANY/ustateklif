-- Tamİşim v14 — askıya alınmış hesap doğrulama RPC sertleştirmesi
-- Paket 5, suspended hesabın sync_my_verification() çağırabildiğini gösterdi.

create or replace function public.sync_my_verification()
returns public.profiles
language plpgsql
security definer
set search_path=public,auth
as $$
declare r public.profiles;
begin
  if auth.uid() is null then
    raise exception 'Oturum gerekli';
  end if;

  if not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  update public.profiles p
     set phone_verified = exists(
       select 1
       from auth.users u
       where u.id=auth.uid()
         and u.phone_confirmed_at is not null
     )
   where p.id=auth.uid()
  returning p.* into r;

  return r;
end
$$;

revoke all on function public.sync_my_verification() from public;
grant execute on function public.sync_my_verification() to authenticated;
