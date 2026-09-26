
begin;

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.notify_nearby_job() from public, anon, authenticated;
revoke all on function public.notify_new_message() from public, anon, authenticated;
revoke all on function public.notify_new_quote() from public, anon, authenticated;
revoke all on function public.sync_payment_transaction_from_choice() from public, anon, authenticated;

revoke execute on function public.is_party(bigint) from anon;

commit;
