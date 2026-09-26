-- Sprint 1 regression matrix. All fixtures and mutations are rolled back.
BEGIN;
SET LOCAL statement_timeout='60s';

DO $test$
DECLARE
  customer uuid:=gen_random_uuid();
  expert uuid:=gen_random_uuid();
  all_city_expert uuid:=gen_random_uuid();
  incomplete_user uuid:=gen_random_uuid();
  admin_user uuid:=gen_random_uuid();
  promo uuid:=gen_random_uuid();
  mezitli bigint; yenisehir bigint; tarsus bigint; paint bigint; adana bigint; blocked_job bigint;
  chosen_quote bigint;
  denied boolean;
  results jsonb:='[]'::jsonb;
BEGIN
  INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES
    (customer,customer||'@example.invalid','{"name":"Rollback customer"}'),
    (expert,expert||'@example.invalid','{"name":"Rollback district expert"}'),
    (all_city_expert,all_city_expert||'@example.invalid','{"name":"Rollback city expert"}'),
    (incomplete_user,incomplete_user||'@example.invalid','{"name":"Rollback incomplete"}'),
    (admin_user,admin_user||'@example.invalid','{"name":"Rollback admin"}');
  INSERT INTO public.admin_users(user_id) VALUES(admin_user);

  UPDATE public.profiles SET name='Rollback district expert',title='Klima uzmanı',
    bio='Rollback test uzman profili',service_categories=ARRAY['klima'],
    service_city='Mersin',service_districts=ARRAY['Mezitli','Yenişehir']
  WHERE id=expert;
  UPDATE public.profiles SET name='Rollback city expert',title='Klima uzmanı',
    bio='Rollback test uzman profili',service_categories=ARRAY['klima'],
    service_city='Mersin',service_districts='{}'
  WHERE id=all_city_expert;

  -- 1: New customer's expert state drives the frontend onboarding branch.
  IF (SELECT expert_status FROM public.profiles WHERE id=incomplete_user)<>'not_started'
     OR (SELECT cardinality(service_categories) FROM public.profiles WHERE id=incomplete_user)<>0
  THEN RAISE EXCEPTION 'T01 onboarding state'; END IF;
  results:=results||jsonb_build_object('test',1,'result','PASS');

  PERFORM set_config('request.jwt.claim.sub',customer::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.listings(owner,category,problems,area,city,district) VALUES
    (customer,'klima',ARRAY['Test'],'Test','Mersin','Mezitli') RETURNING id INTO mezitli;
  INSERT INTO public.listings(owner,category,problems,area,city,district) VALUES
    (customer,'klima',ARRAY['Test'],'Test','Mersin','Yenişehir') RETURNING id INTO yenisehir;
  INSERT INTO public.listings(owner,category,problems,area,city,district) VALUES
    (customer,'klima',ARRAY['Test'],'Test','Mersin','Tarsus') RETURNING id INTO tarsus;
  INSERT INTO public.listings(owner,category,problems,area,city,district) VALUES
    (customer,'boya',ARRAY['Test'],'Test','Mersin','Mezitli') RETURNING id INTO paint;
  INSERT INTO public.listings(owner,category,problems,area,city,district) VALUES
    (customer,'klima',ARRAY['Test'],'Test','Adana','Seyhan') RETURNING id INTO adana;

  -- 2: Incomplete expert cannot bypass the frontend through direct INSERT.
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',incomplete_user::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;
  BEGIN
    INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(mezitli,incomplete_user,100,'Test');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'T02 incomplete direct quote'; END IF;
  results:=results||jsonb_build_object('test',2,'result','PASS');

  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',expert::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- 3-5: Same category/city is visible; district is only a priority group.
  IF NOT EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=mezitli) THEN RAISE EXCEPTION 'T03 Mezitli'; END IF;
  results:=results||jsonb_build_object('test',3,'result','PASS');
  IF NOT EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=yenisehir) THEN RAISE EXCEPTION 'T04 Yenisehir'; END IF;
  results:=results||jsonb_build_object('test',4,'result','PASS');
  IF NOT EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=tarsus)
     OR EXISTS(SELECT 1 FROM unnest((SELECT service_districts FROM public.profiles WHERE id=expert)) d WHERE lower(trim(d))=lower('Tarsus'))
  THEN RAISE EXCEPTION 'T05 Tarsus other-city group'; END IF;
  results:=results||jsonb_build_object('test',5,'result','PASS');

  -- 6: Preferred-district miss does not block a quote.
  INSERT INTO public.quotes(listing_id,pro,price,eta,payment_methods)
    VALUES(tarsus,expert,100,'Test',ARRAY['cash']) RETURNING id INTO chosen_quote;
  results:=results||jsonb_build_object('test',6,'result','PASS');

  -- 7: Wrong category is hidden and direct INSERT is denied.
  IF EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=paint) THEN RAISE EXCEPTION 'T07 paint visible'; END IF;
  denied:=false;
  BEGIN INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(paint,expert,100,'Test');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'T07 paint quote'; END IF;
  results:=results||jsonb_build_object('test',7,'result','PASS');

  -- 8: Another city is hidden and direct INSERT is denied.
  IF EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=adana) THEN RAISE EXCEPTION 'T08 Adana visible'; END IF;
  denied:=false;
  BEGIN INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(adana,expert,100,'Test');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'T08 Adana quote'; END IF;
  results:=results||jsonb_build_object('test',8,'result','PASS');

  -- 9: Empty district preferences permit all districts in the configured city.
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',all_city_expert::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(yenisehir,all_city_expert,110,'Test');
  IF NOT EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=mezitli)
     OR NOT EXISTS(SELECT 1 FROM public.expert_job_pool() WHERE id=tarsus)
  THEN RAISE EXCEPTION 'T09 empty districts'; END IF;
  results:=results||jsonb_build_object('test',9,'result','PASS');

  -- 10: A block in either direction denies a new quote.
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',customer::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.listings(owner,category,problems,area,city,district)
    VALUES(customer,'klima',ARRAY['Test'],'Test','Mersin','Mezitli') RETURNING id INTO blocked_job;
  INSERT INTO public.user_blocks(blocker_id,blocked_id) VALUES(customer,expert);
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',expert::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;
  BEGIN INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(blocked_job,expert,100,'Test');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'T10 blocked quote'; END IF;
  results:=results||jsonb_build_object('test',10,'result','PASS');
  EXECUTE 'RESET ROLE';
  DELETE FROM public.user_blocks WHERE blocker_id=customer AND blocked_id=expert;

  -- 11: Suspended profiles are neither eligible nor directory members.
  UPDATE public.profiles SET account_status='suspended' WHERE id=all_city_expert;
  PERFORM set_config('request.jwt.claim.sub',all_city_expert::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;
  BEGIN INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(mezitli,all_city_expert,120,'Test');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  IF NOT denied OR EXISTS(SELECT 1 FROM public.expert_authorizations() WHERE user_id=all_city_expert)
  THEN RAISE EXCEPTION 'T11 suspended'; END IF;
  results:=results||jsonb_build_object('test',11,'result','PASS');

  -- 13-14: Customer selection stays atomic with payment, promotion and chat.
  EXECUTE 'RESET ROLE';
  INSERT INTO public.promotions(id,code,title,description,discount_type,discount_value,status)
    VALUES(promo,'ROLLBACK-'||promo,'Rollback','Rollback only','fixed',10,'active');
  PERFORM set_config('request.jwt.claim.sub',customer::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.choose_quote_with_payment(tarsus,chosen_quote,'cash',NULL::smallint,promo);
  INSERT INTO public.messages(listing_id,sender,body) VALUES(tarsus,customer,'Rollback customer message');
  IF NOT EXISTS(SELECT 1 FROM public.listings WHERE id=tarsus AND status='chosen')
     OR NOT EXISTS(SELECT 1 FROM public.listing_payment_choices WHERE listing_id=tarsus AND method='cash')
  THEN RAISE EXCEPTION 'T13 create/select'; END IF;
  results:=results||jsonb_build_object('test',13,'result','PASS');
  IF NOT EXISTS(SELECT 1 FROM public.promo_redemptions WHERE listing_id=tarsus AND discount_amount=10)
     OR NOT EXISTS(SELECT 1 FROM public.payment_transactions WHERE listing_id=tarsus AND method='cash')
  THEN RAISE EXCEPTION 'T14 payment/promo'; END IF;
  results:=results||jsonb_build_object('test',14,'result','PASS');

  -- 12: Removing new-profile eligibility does not erase historical party access.
  EXECUTE 'RESET ROLE';
  UPDATE public.profiles SET service_categories='{}' WHERE id=expert;
  PERFORM set_config('request.jwt.claim.sub',expert::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.messages(listing_id,sender,body) VALUES(tarsus,expert,'Rollback legacy reply');
  IF NOT EXISTS(SELECT 1 FROM public.quotes WHERE id=chosen_quote)
     OR NOT EXISTS(SELECT 1 FROM public.listings WHERE id=tarsus)
     OR NOT EXISTS(SELECT 1 FROM public.messages WHERE listing_id=tarsus)
     OR NOT EXISTS(SELECT 1 FROM public.payment_transactions WHERE listing_id=tarsus)
  THEN RAISE EXCEPTION 'T12 legacy access'; END IF;
  denied:=false;
  BEGIN INSERT INTO public.quotes(listing_id,pro,price,eta) VALUES(mezitli,expert,100,'Test');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'T12 legacy new quote'; END IF;
  results:=results||jsonb_build_object('test',12,'result','PASS');

  -- 15: Plain customers are not returned by the server-backed directory source.
  IF EXISTS(SELECT 1 FROM public.expert_authorizations() WHERE user_id IN(customer,incomplete_user))
  THEN RAISE EXCEPTION 'T15 customer in directory'; END IF;
  results:=results||jsonb_build_object('test',15,'result','PASS');

  -- 16: District limits nearby_job only, not feed/quote authorization.
  EXECUTE 'RESET ROLE';
  IF NOT EXISTS(SELECT 1 FROM public.notifications WHERE user_id=expert AND listing_id=mezitli AND type='nearby_job')
     OR NOT EXISTS(SELECT 1 FROM public.notifications WHERE user_id=expert AND listing_id=yenisehir AND type='nearby_job')
     OR EXISTS(SELECT 1 FROM public.notifications WHERE user_id=expert AND listing_id=tarsus AND type='nearby_job')
     OR EXISTS(SELECT 1 FROM public.notifications WHERE user_id=expert AND listing_id=paint AND type='nearby_job')
     OR EXISTS(SELECT 1 FROM public.notifications WHERE user_id=expert AND listing_id=adana AND type='nearby_job')
  THEN RAISE EXCEPTION 'T16 notification matrix'; END IF;
  results:=results||jsonb_build_object('test',16,'result','PASS');

  PERFORM set_config('tamisim.sprint1_results',results::text,true);
END $test$;

SELECT current_setting('tamisim.sprint1_results')::jsonb AS results;
ROLLBACK;
