-- Sprint 5C rollback-only regression test. Leaves no production rows.
begin;

do $test$
declare
  c constant uuid := '2e687688-b840-4fc3-88fe-2ad8d206b716';
  p constant uuid := '994f3165-3682-47a5-86a4-85cda75353b7';
  outsider constant uuid := '2d79e6e0-0ce6-4fed-abf1-e156d2bd2a5b';
  lid bigint;
  qid bigint;
  before_n integer;
  after_n integer;
  i integer;
  bad text;
begin
  insert into public.listings(owner,category,problems,note,area,city,district,when_text)
  values(c,'klima',array['Test klima'],'rollback test','Mezitli, Mersin','Mersin','Mezitli','Bu hafta')
  returning id into lid;
  insert into public.quotes(listing_id,pro,price,eta,note)
  values(lid,p,5000,'Yarın','rollback test') returning id into qid;

  perform set_config('request.jwt.claim.sub',p::text,true);
  begin
    perform public.send_preselection_message(qid,'İlk mesajı ben atayım','00000000-0000-4000-8000-000000000001');
    raise exception 'TEST professional started thread';
  exception when others then
    if sqlerrm not like '%preselection_customer_must_start%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub',c::text,true);
  select count(*) into before_n from public.notifications;
  perform public.send_preselection_message(qid,'5000 TL olur mu?','00000000-0000-4000-8000-000000000002');
  perform public.send_preselection_message(qid,'5000 TL olur mu?','00000000-0000-4000-8000-000000000002');
  select count(*) into after_n from public.notifications;
  if after_n <> before_n + 1 then raise exception 'TEST duplicate notification'; end if;
  if (select count(*) from public.preselection_messages where quote_id=qid) <> 1 then
    raise exception 'TEST duplicate message';
  end if;

  foreach bad in array array[
    'Beni 0555 555 55 55 ara',
    'Numaram +90 555 555 55 55',
    'mail test@example.com',
    'https://example.com',
    'www.example.com',
    'WhatsApp üzerinden yaz',
    'Telegram kullanıyorum',
    'Instagram hesabım var',
    '@kullaniciadi'
  ] loop
    begin
      perform public.send_preselection_message(qid,bad,gen_random_uuid());
      raise exception 'TEST contact accepted: %',bad;
    exception when others then
      if sqlerrm not like '%preselection_contact_forbidden%' then raise; end if;
    end;
  end loop;

  begin
    perform public.send_preselection_message(qid,repeat('a',501),gen_random_uuid());
    raise exception 'TEST maxlength accepted';
  exception when others then
    if sqlerrm not like '%preselection_message_length%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub',p::text,true);
  perform public.send_preselection_message(qid,'Evet, fiyat uygundur.','00000000-0000-4000-8000-000000000003');

  perform set_config('request.jwt.claim.sub',outsider::text,true);
  begin
    perform public.send_preselection_message(qid,'Yetkisiz mesaj','00000000-0000-4000-8000-000000000004');
    raise exception 'TEST outsider accepted';
  exception when others then
    if sqlerrm not like '%preselection_forbidden%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub',c::text,true);
  for i in 1..9 loop
    perform public.send_preselection_message(qid,'Ek soru '||i,gen_random_uuid());
  end loop;
  begin
    perform public.send_preselection_message(qid,'On birinci mesaj',gen_random_uuid());
    raise exception 'TEST limit accepted';
  exception when others then
    if sqlerrm not like '%preselection_message_limit%' then raise; end if;
  end;

  insert into public.user_blocks(blocker_id,blocked_id) values(c,p);
  begin
    perform public.send_preselection_message(qid,'Engel testi',gen_random_uuid());
    raise exception 'TEST blocked pair accepted';
  exception when others then
    if sqlerrm not like '%preselection_blocked%' then raise; end if;
  end;
  delete from public.user_blocks where blocker_id=c and blocked_id=p;

  update public.listings set status='chosen',chosen_quote=qid where id=lid;
  perform set_config('request.jwt.claim.sub',p::text,true);
  begin
    perform public.send_preselection_message(qid,'Seçim sonrası mesaj',gen_random_uuid());
    raise exception 'TEST closed thread accepted';
  exception when others then
    if sqlerrm not like '%preselection_thread_closed%' then raise; end if;
  end;

  if (select count(*) from public.preselection_messages where quote_id=qid) <> 11 then
    raise exception 'TEST history lost';
  end if;
end
$test$;

set local role authenticated;
select set_config('request.jwt.claim.sub','2e687688-b840-4fc3-88fe-2ad8d206b716',true);
do $rls_customer$
begin
  if (select count(*) from public.preselection_messages) <> 11 then
    raise exception 'TEST customer RLS visibility';
  end if;
end
$rls_customer$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','994f3165-3682-47a5-86a4-85cda75353b7',true);
do $rls_professional$
begin
  if (select count(*) from public.preselection_messages) <> 11 then
    raise exception 'TEST professional RLS visibility';
  end if;
end
$rls_professional$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','2d79e6e0-0ce6-4fed-abf1-e156d2bd2a5b',true);
do $rls_outsider$
begin
  if (select count(*) from public.preselection_messages) <> 0 then
    raise exception 'TEST outsider RLS leak';
  end if;
end
$rls_outsider$;
reset role;

do $grants$
begin
  if has_table_privilege('anon','public.preselection_messages','select') then
    raise exception 'TEST anon select grant';
  end if;
  if has_table_privilege('authenticated','public.preselection_messages','insert') then
    raise exception 'TEST authenticated direct insert grant';
  end if;
  if has_function_privilege('anon','public.send_preselection_message(bigint,text,uuid)','execute') then
    raise exception 'TEST anon rpc execute';
  end if;
  if not has_function_privilege('authenticated','public.send_preselection_message(bigint,text,uuid)','execute') then
    raise exception 'TEST authenticated rpc missing';
  end if;
end
$grants$;

select 'PRESELECTION_ROLLBACK_TEST_PASS' as result;
rollback;
