-- TamIsim Sprint 2 regression matrix. Every fixture and mutation is rolled back.
begin;
set local statement_timeout='90s';

do $test$
declare
  customer uuid:=gen_random_uuid();
  expert uuid:=gen_random_uuid();
  wrong_category uuid:=gen_random_uuid();
  wrong_city uuid:=gen_random_uuid();
  legacy uuid:=gen_random_uuid();
  admin_user uuid:=gen_random_uuid();
  partner_user uuid:=gen_random_uuid();
  v_partner_id uuid:=gen_random_uuid();
  promo_id uuid:=gen_random_uuid();
  verification_id uuid:=gen_random_uuid();
  listing_main bigint; listing_wrong_category bigint; listing_wrong_city bigint;
  listing_blocked bigint; listing_card bigint; listing_deposit bigint; listing_partner bigint;
  quote_main bigint; quote_card bigint; quote_deposit bigint; legacy_quote bigint;
  denied boolean;
  results jsonb:='[]'::jsonb;
begin
  insert into auth.users(id,email,raw_user_meta_data) values
    (customer,customer||'@example.invalid','{"name":"S2 customer"}'),
    (expert,expert||'@example.invalid','{"name":"S2 expert"}'),
    (wrong_category,wrong_category||'@example.invalid','{"name":"S2 wrong category"}'),
    (wrong_city,wrong_city||'@example.invalid','{"name":"S2 wrong city"}'),
    (legacy,legacy||'@example.invalid','{"name":"S2 legacy"}'),
    (admin_user,admin_user||'@example.invalid','{"name":"S2 admin"}'),
    (partner_user,partner_user||'@example.invalid','{"name":"S2 partner"}');
  insert into public.admin_users(user_id) values(admin_user);

  update public.profiles set name='S2 expert',title='Klima uzmanı',bio='Sprint iki rollback uzmanı',
    service_categories=array['klima'],service_city='Mersin',service_districts=array['Mezitli'] where id=expert;
  update public.profiles set name='S2 boya',title='Boya uzmanı',bio='Sprint iki rollback uzmanı',
    service_categories=array['boya'],service_city='Mersin' where id=wrong_category;
  update public.profiles set name='S2 Adana',title='Klima uzmanı',bio='Sprint iki rollback uzmanı',
    service_categories=array['klima'],service_city='Adana' where id=wrong_city;
  update public.profiles set name='S2 legacy',title='Klima uzmanı',bio='Sprint iki rollback uzmanı',
    service_categories=array['klima'],service_city='Mersin' where id=legacy;

  -- 1-2: normal customer can create and read own listing through RLS.
  perform set_config('request.jwt.claim.sub',customer::text,true);
  execute 'set local role authenticated';
  insert into public.listings(owner,category,problems,area,city,district)
    values(customer,'klima',array['Test'],'Test','Mersin','Mezitli') returning id into listing_main;
  results:=results||jsonb_build_object('test',1,'result','PASS');
  if not exists(select 1 from public.listings where id=listing_main and owner=customer) then
    raise exception 'T02 owner cannot read listing'; end if;
  results:=results||jsonb_build_object('test',2,'result','PASS');
  insert into public.listings(owner,category,problems,area,city,district)
    values(customer,'boya',array['Test'],'Test','Mersin','Mezitli') returning id into listing_wrong_category;
  insert into public.listings(owner,category,problems,area,city,district)
    values(customer,'klima',array['Test'],'Test','Adana','Seyhan') returning id into listing_wrong_city;
  insert into public.listings(owner,category,problems,area,city,district)
    values(customer,'klima',array['Test'],'Test','Mersin','Mezitli') returning id into listing_blocked;
  insert into public.listings(owner,category,problems,area,city,district)
    values(customer,'klima',array['Test'],'Test','Mersin','Yenişehir') returning id into listing_card;
  insert into public.listings(owner,category,problems,area,city,district)
    values(customer,'klima',array['Test'],'Test','Mersin','Tarsus') returning id into listing_deposit;

  -- 3: matching active expert receives the server-backed job pool row.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',expert::text,true); execute 'set local role authenticated';
  if not exists(select 1 from public.expert_job_pool() where id=listing_main) then raise exception 'T03 expert pool'; end if;
  results:=results||jsonb_build_object('test',3,'result','PASS');

  -- 4: wrong category direct quote INSERT is denied.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',wrong_category::text,true); execute 'set local role authenticated';
  denied:=false; begin insert into public.quotes(listing_id,pro,price,eta) values(listing_main,wrong_category,100,'Test');
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'T04 wrong category'; end if;
  results:=results||jsonb_build_object('test',4,'result','PASS');

  -- 5: wrong city direct quote INSERT is denied.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',wrong_city::text,true); execute 'set local role authenticated';
  denied:=false; begin insert into public.quotes(listing_id,pro,price,eta) values(listing_main,wrong_city,100,'Test');
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'T05 wrong city'; end if;
  results:=results||jsonb_build_object('test',5,'result','PASS');

  -- 6: bilateral block denies a new quote.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',customer::text,true); execute 'set local role authenticated';
  insert into public.user_blocks(blocker_id,blocked_id) values(customer,expert);
  execute 'reset role'; perform set_config('request.jwt.claim.sub',expert::text,true); execute 'set local role authenticated';
  denied:=false; begin insert into public.quotes(listing_id,pro,price,eta) values(listing_blocked,expert,100,'Test');
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'T06 blocked quote'; end if;
  results:=results||jsonb_build_object('test',6,'result','PASS');
  execute 'reset role'; delete from public.user_blocks where blocker_id=customer and blocked_id=expert;

  -- Prepare valid and legacy quotes before the legacy profile becomes incomplete.
  perform set_config('request.jwt.claim.sub',expert::text,true); execute 'set local role authenticated';
  insert into public.quotes(listing_id,pro,price,eta,payment_methods)
    values(listing_main,expert,500,'Test',array['cash']) returning id into quote_main;
  insert into public.quotes(listing_id,pro,price,eta,payment_methods)
    values(listing_card,expert,600,'Test',array['card']) returning id into quote_card;
  insert into public.quotes(listing_id,pro,price,eta,payment_methods,deposit_percent)
    values(listing_deposit,expert,700,'Test',array['deposit_cash'],30) returning id into quote_deposit;
  execute 'reset role'; perform set_config('request.jwt.claim.sub',legacy::text,true); execute 'set local role authenticated';
  insert into public.quotes(listing_id,pro,price,eta) values(listing_card,legacy,550,'Test') returning id into legacy_quote;
  execute 'reset role'; update public.profiles set service_categories='{}' where id=legacy;
  perform set_config('request.jwt.claim.sub',legacy::text,true); execute 'set local role authenticated';
  if not exists(select 1 from public.quotes where id=legacy_quote) then raise exception 'T07 legacy quote'; end if;
  results:=results||jsonb_build_object('test',7,'result','PASS');

  -- 8-10: atomic selection preserves selected-party listing/chat access.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',customer::text,true); execute 'set local role authenticated';
  perform public.choose_quote_with_payment(listing_main,quote_main,'cash',null::smallint,null::uuid);
  insert into public.messages(listing_id,sender,body) values(listing_main,customer,'Sprint 2 rollback message');
  results:=results||jsonb_build_object('test',10,'result','PASS');
  execute 'reset role'; perform set_config('request.jwt.claim.sub',expert::text,true); execute 'set local role authenticated';
  if not exists(select 1 from public.listings where id=listing_main) then raise exception 'T08 selected listing'; end if;
  results:=results||jsonb_build_object('test',8,'result','PASS');
  insert into public.messages(listing_id,sender,body) values(listing_main,expert,'Sprint 2 rollback reply');
  if (select count(*) from public.messages where listing_id=listing_main)<2 then raise exception 'T09 chat'; end if;
  results:=results||jsonb_build_object('test',9,'result','PASS');

  -- 11: listing/quote/message triggers created expected notifications.
  execute 'reset role';
  if not exists(select 1 from public.notifications where user_id=customer and listing_id=listing_main and type='quote')
     or not exists(select 1 from public.notifications where user_id=expert and listing_id=listing_main and type='chosen')
     or not exists(select 1 from public.notifications where listing_id=listing_main and type='message')
  then raise exception 'T11 notifications'; end if;
  results:=results||jsonb_build_object('test',11,'result','PASS');

  -- 12-13: promo and all three payment choice shapes remain functional.
  insert into public.promotions(id,code,title,discount_type,discount_value,status)
    values(promo_id,'S2-'||promo_id,'Sprint 2','fixed',25,'active');
  perform set_config('request.jwt.claim.sub',customer::text,true); execute 'set local role authenticated';
  perform public.choose_quote_with_payment(listing_card,quote_card,'card',null::smallint,promo_id);
  perform public.choose_quote_with_payment(listing_deposit,quote_deposit,'deposit_cash',30::smallint,null::uuid);
  if not exists(select 1 from public.promo_redemptions where listing_id=listing_card and discount_amount=25) then
    raise exception 'T12 promotion'; end if;
  results:=results||jsonb_build_object('test',12,'result','PASS');
  if not exists(select 1 from public.listing_payment_choices where listing_id=listing_main and method='cash')
     or not exists(select 1 from public.listing_payment_choices where listing_id=listing_card and method='card')
     or not exists(select 1 from public.listing_payment_choices where listing_id=listing_deposit and method='deposit_cash' and deposit_percent=30)
  then raise exception 'T13 payment choices'; end if;
  results:=results||jsonb_build_object('test',13,'result','PASS');

  -- 14: verification insert is user-scoped; admin review is backend-authorized.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',expert::text,true); execute 'set local role authenticated';
  insert into public.professional_verifications(user_id,category,verification_type,document_type,storage_path)
    values(expert,'klima','certificate','rollback','rollback/'||verification_id)
    returning id into verification_id;
  denied:=false; begin perform public.admin_review_verification(verification_id,'approved',null);
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'T14 non-admin reviewed verification'; end if;
  execute 'reset role'; perform set_config('request.jwt.claim.sub',admin_user::text,true); execute 'set local role authenticated';
  perform public.admin_review_verification(verification_id,'approved','rollback');
  if (select status from public.professional_verifications where id=verification_id)<>'approved' then raise exception 'T14 admin review'; end if;
  results:=results||jsonb_build_object('test',14,'result','PASS');

  -- 15-17: reports, support and deletion requests remain usable with narrowed grants.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',customer::text,true); execute 'set local role authenticated';
  insert into public.reports(reporter_id,reported_id,listing_id,reason)
    values(customer,expert,listing_main,'Sprint two rollback report');
  results:=results||jsonb_build_object('test',15,'result','PASS');
  insert into public.support_requests(user_id,category,subject,message)
    values(customer,'general','Rollback','Sprint two rollback support request');
  results:=results||jsonb_build_object('test',16,'result','PASS');
  insert into public.account_deletion_requests(user_id,reason)
    values(customer,'Sprint two rollback deletion request');
  results:=results||jsonb_build_object('test',17,'result','PASS');

  -- 18: partner membership and category filtering remain separate from experts.
  execute 'reset role';
  insert into public.partners(id,name,slug,status,service_categories)
    values(v_partner_id,'Sprint 2 Partner','s2-'||v_partner_id,'active',array['klima']);
  insert into public.partner_members(partner_id,user_id,role,status)
    values(v_partner_id,partner_user,'owner','active');
  insert into public.listings(owner,category,problems,area,city,district,source_kind,partner_id)
    values(customer,'klima',array['Test'],'Test','Mersin','Mezitli','partner',v_partner_id) returning id into listing_partner;
  perform set_config('request.jwt.claim.sub',partner_user::text,true); execute 'set local role authenticated';
  if (select c.partner_id from public.my_partner_context() c) is distinct from v_partner_id
     or not exists(select 1 from public.my_partner_jobs() where listing_id=listing_partner)
  then raise exception 'T18 partner access'; end if;
  results:=results||jsonb_build_object('test',18,'result','PASS');

  -- 19: a normal authenticated user cannot execute an admin operation.
  execute 'reset role'; perform set_config('request.jwt.claim.sub',customer::text,true); execute 'set local role authenticated';
  denied:=false; begin perform public.admin_set_account_status(expert,'suspended');
  exception when others then denied:=true; end;
  if not denied then raise exception 'T19 admin RPC'; end if;
  results:=results||jsonb_build_object('test',19,'result','PASS');

  -- 20: Sprint 1 onboarding state and quote authorization are unchanged.
  if (select expert_status from public.profiles where id=customer)<>'not_started'
     or public.quote_eligibility(listing_wrong_category) is null
  then raise exception 'T20 Sprint 1 behavior'; end if;
  results:=results||jsonb_build_object('test',20,'result','PASS');

  execute 'reset role';
  perform set_config('tamisim.sprint2_results',results::text,true);
end $test$;

select current_setting('tamisim.sprint2_results')::jsonb as results;
rollback;
