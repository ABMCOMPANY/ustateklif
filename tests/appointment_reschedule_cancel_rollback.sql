-- Run after the candidate migration in an isolated database or within the SAME
-- outer transaction with migration BEGIN/COMMIT removed. Never commit fixtures.
-- All identities below are synthetic and inserted inside this rollback scope.
begin;
create temporary table _a2_results(test text primary key, result text not null) on commit drop;
create temporary table _a2_ids(l bigint, q bigint) on commit drop;
grant select,insert,update on _a2_results,_a2_ids to authenticated,anon;
create function pg_temp.check_ok(label text, ok boolean) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'TEST FAILED: %',label; end if;
 insert into _a2_results values(label,'PASS');
end $$;
create function pg_temp.reject(label text, statement text, expected text) returns void language plpgsql as $$
begin
 begin
  execute statement;
 exception when others then
  if sqlstate = expected then
   insert into _a2_results values(label,'PASS'); return;
  end if;
  raise exception 'TEST FAILED: % expected %, got %: %',label,expected,sqlstate,sqlerrm;
 end;
 raise exception 'TEST FAILED: % unexpectedly accepted',label;
end $$;
insert into auth.users(id,email) values
 ('60000000-0000-4000-8000-000000000001','a2-customer@example.invalid'),('60000000-0000-4000-8000-000000000002','a2-pro@example.invalid'),
 ('60000000-0000-4000-8000-000000000003','a2-outsider@example.invalid'),('60000000-0000-4000-8000-000000000004','a2-wrong-pro@example.invalid');
update public.profiles set name='Rollback expert',title='Klima bakımı',bio='Test uzman profili',
 service_categories=array['klima'],service_city='Mersin',service_districts=array['Mezitli']
 where id in ('60000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000004');
with l as (insert into public.listings(owner,category,problems,area,city,district,when_text)
 values('60000000-0000-4000-8000-000000000001','klima',array['Bakım'],'Mezitli, Mersin','Mersin','Mezitli','Yarın') returning id)
 insert into _a2_ids(l) select id from l;
with q as (insert into public.quotes(listing_id,pro,price,eta,payment_methods)
 select l,'60000000-0000-4000-8000-000000000002',1750,'Yarın',array['cash'] from _a2_ids returning id)
 update _a2_ids set q=(select id from q);
insert into public.quotes(listing_id,pro,price,eta) select l,'60000000-0000-4000-8000-000000000004',1800,'Yarın' from _a2_ids;
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.select_quote((select l from _a2_ids),(select q from _a2_ids));
select public.propose_listing_appointment((select l from _a2_ids),now()+interval '1 day',0);
select pg_temp.check_ok('01 customer initial propose',(select status='awaiting_expert' and revision=1 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select public.accept_listing_appointment((select l from _a2_ids),1);
select pg_temp.check_ok('02 expert accept',(select status='confirmed' and revision=2 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select pg_temp.check_ok('21 initial workflow scheduling',(select state='scheduled' and revision=2 from public.listing_workflows where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.propose_listing_appointment((select l from _a2_ids),now()+interval '2 days',2);
select pg_temp.check_ok('03 customer reschedule',(select status='awaiting_expert' and revision=3 and confirmed_at is null from public.listing_appointments where listing_id=(select l from _a2_ids)));
select public.propose_listing_appointment((select l from _a2_ids),now()+interval '2 days',2);
select pg_temp.check_ok('10 duplicate proposal retry',(select revision=3 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select pg_temp.reject('07 stale revision', $query$select public.propose_listing_appointment((select l from _a2_ids),now()+interval '3 days',1)$query$,'40001');
select pg_temp.reject('25 null revision', $query$select public.propose_listing_appointment((select l from _a2_ids),now()+interval '3 days',null)$query$,'40001');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_temp.reject('26 no departure during reschedule', $query$select public.advance_listing_workflow((select l from _a2_ids),'en_route',(select revision from public.listing_workflows where listing_id=(select l from _a2_ids)),gen_random_uuid())$query$,'42501');
select pg_temp.reject('55 stale accept',$query$select public.accept_listing_appointment((select l from _a2_ids),1)$query$,'40001');
select public.accept_listing_appointment((select l from _a2_ids),3);
select pg_temp.check_ok('54 reschedule keeps scheduled', (select state='scheduled' from public.listing_workflows where listing_id=(select l from _a2_ids)));
select pg_temp.check_ok('04 expert accepts reschedule',(select status='confirmed' and revision=4 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select public.accept_listing_appointment((select l from _a2_ids),3);
select pg_temp.check_ok('11 duplicate accept retry',(select revision=4 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select public.propose_listing_appointment((select l from _a2_ids),now()+interval '3 days',4);
select pg_temp.check_ok('05 expert reschedule',(select status='awaiting_customer' and revision=5 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.accept_listing_appointment((select l from _a2_ids),5);
select pg_temp.check_ok('06 customer accepts',(select status='confirmed' and revision=6 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000003',true);
select pg_temp.reject('08 outsider', $query$select public.cancel_listing_appointment((select l from _a2_ids),6,null)$query$,'42501');
select pg_temp.reject('27 outsider propose', $query$select public.propose_listing_appointment((select l from _a2_ids),now()+interval '4 days',6)$query$,'42501');
select pg_temp.reject('28 outsider accept', $query$select public.accept_listing_appointment((select l from _a2_ids),6)$query$,'42501');
select pg_temp.check_ok('29 outsider RLS',(select count(*)=0 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000004',true);
select pg_temp.reject('09 wrong professional', $query$select public.cancel_listing_appointment((select l from _a2_ids),6,null)$query$,'42501');
select pg_temp.check_ok('30 wrong professional RLS',(select count(*)=0 from public.listing_appointments where listing_id=(select l from _a2_ids)));
reset role; set local role anon;
select set_config('request.jwt.claim.sub','',true);
select pg_temp.reject('31 anon RPC', $query$select public.cancel_listing_appointment((select l from _a2_ids),6,null)$query$,'42501');
select pg_temp.reject('32 anon table', $query$select * from public.listing_appointments where listing_id=(select l from _a2_ids)$query$,'42501');
reset role; set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_temp.reject('14 cancel stale', $query$select public.cancel_listing_appointment((select l from _a2_ids),5,null)$query$,'40001');
select public.cancel_listing_appointment((select l from _a2_ids),6,'  Plan değişti  ');
select pg_temp.check_ok('12 customer cancel',(select status='cancelled' and revision=7 and cancelled_by='60000000-0000-4000-8000-000000000001' and cancel_reason='Plan değişti' from public.listing_appointments where listing_id=(select l from _a2_ids)));
select public.cancel_listing_appointment((select l from _a2_ids),6,'Plan değişti');
select pg_temp.check_ok('15 duplicate cancel',(select revision=7 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select pg_temp.check_ok('16 cancel resets workflow',(select state='awaiting_appointment' from public.listing_workflows where listing_id=(select l from _a2_ids)));
select pg_temp.check_ok('33 selection retained',(select status='chosen' and chosen_quote=(select q from _a2_ids) from public.listings where id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_temp.reject('34 restart customer only', $query$select public.propose_listing_appointment((select l from _a2_ids),now()+interval '4 days',7)$query$,'42501');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.propose_listing_appointment((select l from _a2_ids),now()+interval '4 days',7);
select pg_temp.check_ok('17 restart proposal',(select status='awaiting_expert' and revision=8 and cancelled_at is not null and cancel_reason='Plan değişti' from public.listing_appointments where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select public.accept_listing_appointment((select l from _a2_ids),8);
select public.cancel_listing_appointment((select l from _a2_ids),9,'<b>Plan</b>');
select pg_temp.check_ok('13 expert cancel',(select status='cancelled' and revision=10 and cancelled_by='60000000-0000-4000-8000-000000000002' from public.listing_appointments where listing_id=(select l from _a2_ids)));
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.propose_listing_appointment((select l from _a2_ids),now()+interval '5 days',10);
insert into public.user_blocks(blocker_id,blocked_id) values('60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002');
select pg_temp.reject('35 block cancel', $query$select public.cancel_listing_appointment((select l from _a2_ids),11,null)$query$,'42501');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_temp.reject('36 block accept', $query$select public.accept_listing_appointment((select l from _a2_ids),11)$query$,'42501');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
delete from public.user_blocks where blocker_id='60000000-0000-4000-8000-000000000001' and blocked_id='60000000-0000-4000-8000-000000000002';
reset role; update public.profiles set account_status='suspended' where id='60000000-0000-4000-8000-000000000002'; set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_temp.reject('37 suspended actor', $query$select public.accept_listing_appointment((select l from _a2_ids),11)$query$,'42501');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_temp.reject('38 suspended counterparty', $query$select public.cancel_listing_appointment((select l from _a2_ids),11,null)$query$,'42501');
reset role; update public.profiles set account_status='active' where id='60000000-0000-4000-8000-000000000002'; set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select public.accept_listing_appointment((select l from _a2_ids),11);
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_temp.reject('39 past proposal', $query$select public.propose_listing_appointment((select l from _a2_ids),now()-interval '1 day',12)$query$,'P0001');
select pg_temp.reject('40 horizon', $query$select public.propose_listing_appointment((select l from _a2_ids),now()+interval '91 days',12)$query$,'P0001');
select pg_temp.reject('41 reason length', $query$select public.cancel_listing_appointment((select l from _a2_ids),12,repeat('a',501))$query$,'22023');
select pg_temp.reject('42 direct appointment update', $query$update public.listing_appointments set status='cancelled' where listing_id=(select l from _a2_ids)$query$,'42501');
select pg_temp.reject('43 direct appointment insert', $query$insert into public.listing_appointments(listing_id) values((select l from _a2_ids))$query$,'42501');
select pg_temp.reject('44 direct workflow update', $query$update public.listing_workflows set state='scheduled' where listing_id=(select l from _a2_ids)$query$,'42501');
select pg_temp.check_ok('24 RLS direct bypass',not has_table_privilege('authenticated','public.listing_appointments','UPDATE') and not has_table_privilege('authenticated','public.listing_workflows','UPDATE'));
select public.set_listing_payment_choice((select l from _a2_ids),'cash');
select pg_temp.check_ok('45 payment independent',exists(select 1 from public.listing_payment_choices where listing_id=(select l from _a2_ids)));
insert into public.messages(listing_id,sender,body) values((select l from _a2_ids),'60000000-0000-4000-8000-000000000001','Randevu test mesajı');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_temp.check_ok('46 selected chat',exists(select 1 from public.messages where listing_id=(select l from _a2_ids) and body='Randevu test mesajı'));
select public.advance_listing_workflow((select l from _a2_ids),'en_route',(select revision from public.listing_workflows where listing_id=(select l from _a2_ids)),'60000000-0000-4000-8000-000000000010');
select pg_temp.check_ok('22 depart regression',(select state='en_route' from public.listing_workflows where listing_id=(select l from _a2_ids)));
select pg_temp.reject('18 en route cancel', $query$select public.cancel_listing_appointment((select l from _a2_ids),12,null)$query$,'42501');
select pg_temp.reject('47 en route reschedule', $query$select public.propose_listing_appointment((select l from _a2_ids),now()+interval '6 days',12)$query$,'42501');
select public.advance_listing_workflow((select l from _a2_ids),'in_progress',(select revision from public.listing_workflows where listing_id=(select l from _a2_ids)),gen_random_uuid());
select pg_temp.reject('19 in progress cancel', $query$select public.cancel_listing_appointment((select l from _a2_ids),12,null)$query$,'42501');
select public.advance_listing_workflow((select l from _a2_ids),'completion_requested',(select revision from public.listing_workflows where listing_id=(select l from _a2_ids)),gen_random_uuid());
select pg_temp.reject('48 completion requested cancel', $query$select public.cancel_listing_appointment((select l from _a2_ids),12,null)$query$,'42501');
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.advance_listing_workflow((select l from _a2_ids),'completed',(select revision from public.listing_workflows where listing_id=(select l from _a2_ids)),gen_random_uuid());
select pg_temp.reject('20 completed cancel', $query$select public.cancel_listing_appointment((select l from _a2_ids),12,null)$query$,'42501');
select pg_temp.check_ok('49 completion regression',(select status='done' from public.listings where id=(select l from _a2_ids)));
select public.submit_job_review((select l from _a2_ids),5,'Tamamlandı',gen_random_uuid());
select pg_temp.check_ok('50 review regression',exists(select 1 from public.job_reviews where listing_id=(select l from _a2_ids) and rating=5));
reset role;
select pg_temp.check_ok('23 notification recipient type',(select count(*)=2 from public.notifications where listing_id=(select l from _a2_ids) and type='appointment_reschedule_proposed') and (select count(*)=2 from public.notifications where listing_id=(select l from _a2_ids) and type='appointment_cancelled') and (select count(*)=5 from public.notifications where listing_id=(select l from _a2_ids) and type='appointment_confirmed') and not exists(select 1 from public.notifications where listing_id=(select l from _a2_ids) and type like 'appointment_%' and (user_id=actor_id or user_id not in ('60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002'))) );
select pg_temp.check_ok('51 cancellation reason not in notification',not exists(select 1 from public.notifications where listing_id=(select l from _a2_ids) and body like '%<b>%'));
select pg_temp.check_ok('52 no duplicate rows',(select count(*)=1 from public.listing_appointments where listing_id=(select l from _a2_ids)));
select pg_temp.check_ok('53 grants and search path',not has_function_privilege('anon','public.cancel_listing_appointment(bigint,bigint,text)','EXECUTE') and not has_function_privilege('authenticated','public.schedule_listing_workflow_from_appointment()','EXECUTE') and (select proconfig @> array['search_path=""'] from pg_proc where oid='public.cancel_listing_appointment(bigint,bigint,text)'::regprocedure));

-- Independent pending appointment cancellation (workflow never scheduled).
create temporary table _a2_pending(l bigint,q bigint) on commit drop;
grant select on _a2_pending to authenticated;
with l as (insert into public.listings(owner,category,problems,area,city,district)
 values('60000000-0000-4000-8000-000000000001','klima',array['Bakım'],'Mezitli','Mersin','Mezitli') returning id)
 insert into _a2_pending(l) select id from l;
with q as (insert into public.quotes(listing_id,pro,price,eta,payment_methods)
 select l,'60000000-0000-4000-8000-000000000002',2000,'Yarın',array['cash'] from _a2_pending returning id)
 update _a2_pending set q=(select id from q);
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select public.select_quote((select l from _a2_pending),(select q from _a2_pending));
select public.propose_listing_appointment((select l from _a2_pending),now()+interval '1 day',0);
select pg_temp.reject('56 null cancel revision',$query$select public.cancel_listing_appointment((select l from _a2_pending),null,null)$query$,'40001');
select pg_temp.reject('57 null accept revision',$query$select public.accept_listing_appointment((select l from _a2_pending),null)$query$,'40001');
select public.cancel_listing_appointment((select l from _a2_pending),1,'   ');
select pg_temp.check_ok('58 pending cancellation',
 (select status='cancelled' and revision=2 and cancel_reason is null from public.listing_appointments where listing_id=(select l from _a2_pending))
 and (select state='awaiting_appointment' from public.listing_workflows where listing_id=(select l from _a2_pending)));
select public.propose_listing_appointment((select l from _a2_pending),now()+interval '2 days',2);
select pg_temp.reject('59 stale same-value proposal',$query$select public.propose_listing_appointment((select l from _a2_pending),now()+interval '2 days',0)$query$,'40001');
reset role;

select * from _a2_results order by test;
rollback;
