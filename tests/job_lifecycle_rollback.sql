-- Sprint 6A-1 rollback-only lifecycle/security regression. Leaves no rows.
begin;

create temporary table _s6_ids(
  listing_id bigint,
  quote_id bigint,
  legacy_listing_id bigint,
  legacy_quote_id bigint
) on commit drop;
grant select on _s6_ids to authenticated;

with l as (
  insert into public.listings(owner,category,problems,note,area,city,district,neighborhood,when_text)
  values (
    '2e687688-b840-4fc3-88fe-2ad8d206b716','klima',array['Bakım'],
    'Sprint 6 rollback testi','Efeler, Aydın','Aydın','Efeler','','Yarın'
  ) returning id
)
insert into _s6_ids(listing_id) select id from l;

with q as (
  insert into public.quotes(listing_id,pro,price,eta,note,payment_methods)
  select listing_id,'994f3165-3682-47a5-86a4-85cda75353b7',1750,
         'Yarın','Bakım dahil',array['cash']
  from _s6_ids
  returning id
)
update _s6_ids set quote_id=(select id from q);

select set_config('request.jwt.claim.sub','2e687688-b840-4fc3-88fe-2ad8d206b716',true);
select public.select_quote(listing_id,quote_id) from _s6_ids;
select public.select_quote(listing_id,quote_id) from _s6_ids;

do $test$
declare v_l bigint;
begin
  select listing_id into v_l from _s6_ids;
  if (select count(*) from public.listing_workflows where listing_id=v_l)<>1 then raise exception 'T01 workflow'; end if;
  if (select count(*) from public.job_agreement_snapshots where listing_id=v_l)<>1 then raise exception 'T02 snapshot'; end if;
  if (select count(*) from public.notifications where listing_id=v_l and type='chosen')<>1 then raise exception 'T03 selection retry'; end if;
  if (select quote_price from public.job_agreement_snapshots where listing_id=v_l)<>1750 then raise exception 'T04 snapshot price'; end if;
end $test$;

with l as (
  insert into public.listings(owner,category,problems,note,area,city,district,neighborhood,when_text)
  values (
    '2e687688-b840-4fc3-88fe-2ad8d206b716','klima',array['Montaj'],
    'Legacy seçim rollback testi','Efeler, Aydın','Aydın','Efeler','','Yarın'
  ) returning id
)
update _s6_ids set legacy_listing_id=(select id from l);

with q as (
  insert into public.quotes(listing_id,pro,price,eta,note,payment_methods)
  select legacy_listing_id,'994f3165-3682-47a5-86a4-85cda75353b7',1800,
         'Yarın','Legacy ödeme yolu',array['cash']
  from _s6_ids
  returning id
)
update _s6_ids set legacy_quote_id=(select id from q);

select set_config('request.jwt.claim.sub','2e687688-b840-4fc3-88fe-2ad8d206b716',true);
select public.choose_quote_with_payment(legacy_listing_id,legacy_quote_id,'cash',null,null) from _s6_ids;

do $test$ begin
  if (select count(*) from public.listing_workflows where listing_id=(select legacy_listing_id from _s6_ids))<>1 then raise exception 'T04A legacy workflow'; end if;
  if (select count(*) from public.job_agreement_snapshots where listing_id=(select legacy_listing_id from _s6_ids))<>1 then raise exception 'T04B legacy snapshot'; end if;
end $test$;

select set_config('request.jwt.claim.sub','2d79e6e0-0ce6-4fed-abf1-e156d2bd2a5b',true);
do $test$ begin
  begin
    perform public.advance_listing_workflow((select listing_id from _s6_ids),'en_route',1,'00000000-0000-4000-8000-000000000001');
    raise exception 'T05 outsider accepted';
  exception when sqlstate '42501' then null; end;
end $test$;

select set_config('request.jwt.claim.sub','2e687688-b840-4fc3-88fe-2ad8d206b716',true);
select public.propose_listing_appointment((select listing_id from _s6_ids),now()+interval '1 day',0);

select set_config('request.jwt.claim.sub','994f3165-3682-47a5-86a4-85cda75353b7',true);
select public.accept_listing_appointment((select listing_id from _s6_ids),1);

do $test$ begin
  if (select state from public.listing_workflows where listing_id=(select listing_id from _s6_ids))<>'scheduled' then raise exception 'T06 appointment schedule'; end if;
end $test$;

select set_config('request.jwt.claim.sub','2e687688-b840-4fc3-88fe-2ad8d206b716',true);
do $test$ begin
  begin
    perform public.submit_job_review((select listing_id from _s6_ids),5,'erken','00000000-0000-4000-8000-000000000010');
    raise exception 'T07 early review accepted';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.advance_listing_workflow((select listing_id from _s6_ids),'en_route',2,'00000000-0000-4000-8000-000000000002');
    raise exception 'T08 customer expert transition accepted';
  exception when sqlstate '42501' then null; end;
end $test$;

select set_config('request.jwt.claim.sub','994f3165-3682-47a5-86a4-85cda75353b7',true);
select public.advance_listing_workflow((select listing_id from _s6_ids),'en_route',2,'00000000-0000-4000-8000-000000000002');
select public.advance_listing_workflow((select listing_id from _s6_ids),'en_route',2,'00000000-0000-4000-8000-000000000002');
do $test$ begin
  begin
    perform public.advance_listing_workflow((select listing_id from _s6_ids),'in_progress',2,'00000000-0000-4000-8000-000000000003');
    raise exception 'T09 stale revision accepted';
  exception when sqlstate '40001' then null; end;
end $test$;
select public.advance_listing_workflow((select listing_id from _s6_ids),'in_progress',3,'00000000-0000-4000-8000-000000000003');
select public.advance_listing_workflow((select listing_id from _s6_ids),'completion_requested',4,'00000000-0000-4000-8000-000000000004');

select set_config('request.jwt.claim.sub','2e687688-b840-4fc3-88fe-2ad8d206b716',true);
select public.advance_listing_workflow((select listing_id from _s6_ids),'completed',5,'00000000-0000-4000-8000-000000000005');
select public.advance_listing_workflow((select listing_id from _s6_ids),'completed',5,'00000000-0000-4000-8000-000000000005');

do $test$ begin
  begin
    perform public.complete_listing((select listing_id from _s6_ids),5);
    raise exception 'T10 legacy completion accepted';
  exception when sqlstate '0A000' then null; end;
end $test$;

select public.submit_job_review((select listing_id from _s6_ids),5,'Doğrulanmış rollback yorumu','00000000-0000-4000-8000-000000000006');
select public.submit_job_review((select listing_id from _s6_ids),5,'Doğrulanmış rollback yorumu','00000000-0000-4000-8000-000000000006');

do $test$ begin
  begin
    perform public.submit_job_review((select listing_id from _s6_ids),4,'ikinci','00000000-0000-4000-8000-000000000007');
    raise exception 'T11 second review accepted';
  exception when others then
    if sqlerrm not like '%daha önce%' then raise; end if;
  end;
end $test$;

do $test$
declare v_l bigint;
begin
  select listing_id into v_l from _s6_ids;
  if (select state from public.listing_workflows where listing_id=v_l)<>'completed' then raise exception 'T12 workflow complete'; end if;
  if (select status from public.listings where id=v_l)<>'done' then raise exception 'T13 listing done'; end if;
  if (select count(*) from public.job_reviews where listing_id=v_l)<>1 then raise exception 'T14 review retry'; end if;
  if (select rating from public.listings where id=v_l)<>5 then raise exception 'T15 legacy rating sync'; end if;
  if (select count(*) from public.notifications where listing_id=v_l and type like 'workflow_%')<>4 then raise exception 'T16 workflow notifications'; end if;
  if (select jobs from public.pro_stats where pro_id='994f3165-3682-47a5-86a4-85cda75353b7') <>
     (select count(*) from public.listings l join public.quotes q on q.id=l.chosen_quote where q.pro='994f3165-3682-47a5-86a4-85cda75353b7' and l.status='done') then
    raise exception 'T17 pro stats';
  end if;
end $test$;

set local role authenticated;
select set_config('request.jwt.claim.sub','2d79e6e0-0ce6-4fed-abf1-e156d2bd2a5b',true);
do $test$ begin
  if (select count(*) from public.listing_workflows where listing_id=(select listing_id from _s6_ids))<>0 then raise exception 'T18 workflow RLS'; end if;
  if (select count(*) from public.job_agreement_snapshots where listing_id=(select listing_id from _s6_ids))<>0 then raise exception 'T19 snapshot RLS'; end if;
  if (select count(*) from public.job_reviews where listing_id=(select listing_id from _s6_ids))<>0 then raise exception 'T20 review RLS'; end if;
  begin
    update public.listing_workflows set state='completed' where listing_id=(select listing_id from _s6_ids);
    raise exception 'T21 direct workflow update';
  exception when insufficient_privilege then null; end;
  begin
    update public.job_agreement_snapshots set quote_price=1 where listing_id=(select listing_id from _s6_ids);
    raise exception 'T22 snapshot mutation';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.job_reviews(listing_id,customer_id,professional_id,rating,client_request_id)
    values((select listing_id from _s6_ids),'2e687688-b840-4fc3-88fe-2ad8d206b716','994f3165-3682-47a5-86a4-85cda75353b7',1,gen_random_uuid());
    raise exception 'T23 direct review insert';
  exception when insufficient_privilege then null; end;
end $test$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','994f3165-3682-47a5-86a4-85cda75353b7',true);
do $test$ begin
  if (select count(*) from public.listing_workflows where listing_id=(select listing_id from _s6_ids))<>1 then raise exception 'T24 selected professional RLS'; end if;
end $test$;
reset role;

rollback;
