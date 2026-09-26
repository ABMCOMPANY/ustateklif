-- Tamİşim expert_authorization_v1. Baseline: LIVE 2026-09-26, not legacy setup SQL.
-- No production rows are rewritten. Existing chosen jobs retain their party access.
-- Roll forward on failure after release; restoring broad old policies reopens the vulnerability.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
CREATE SCHEMA IF NOT EXISTS expert_security;
REVOKE ALL ON SCHEMA expert_security FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA expert_security TO authenticated;

-- Internal user-id helpers have NO client EXECUTE grant. Only fixed-auth wrappers below
-- are callable by authenticated users. Business/profile flags are not authority.
CREATE OR REPLACE FUNCTION expert_security.category_error(p_user uuid, p_category text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_user IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_user AND account_status='active') THEN
    RETURN 'Hesabınız şu anda teklif vermeye uygun değil.';
  END IF;
  IF p_category IS NULL OR NOT (p_category = ANY(ARRAY['boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi','elektronik','lastik','oto','temizlik','nakliyat','bahce','ozelders','guzellik','kucukisler','evcilhayvan','diger'])) THEN
    RETURN 'Bu hizmet kategorisi için uzman onayınız bulunmuyor.';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.professional_verifications v WHERE v.user_id=p_user
    AND v.verification_type='identity' AND v.status='approved' AND v.reviewed_by IS NOT NULL
    AND v.reviewed_at IS NOT NULL AND (v.expires_at IS NULL OR v.expires_at>statement_timestamp())) THEN
    RETURN 'Geçerli kimlik doğrulamanız olmadan teklif veremezsiniz.';
  END IF;
  IF EXISTS(SELECT 1 FROM public.professional_verifications v WHERE v.user_id=p_user
    AND v.category=p_category AND v.verification_type IN ('vocational','diploma','certificate')
    AND v.status='approved' AND v.reviewed_by IS NOT NULL AND v.reviewed_at IS NOT NULL
    AND (v.expires_at IS NULL OR v.expires_at>statement_timestamp())) THEN RETURN NULL; END IF;
  IF EXISTS(SELECT 1 FROM public.professional_verifications v WHERE v.user_id=p_user
    AND v.category=p_category AND v.verification_type IN ('vocational','diploma','certificate')
    AND (v.status='expired' OR (v.status='approved' AND v.expires_at<=statement_timestamp()))) THEN
    RETURN 'Uzman belgenizin geçerlilik süresi dolmuş.';
  END IF;
  RETURN 'Bu hizmet kategorisi için uzman onayınız bulunmuyor.';
END $$;

CREATE OR REPLACE FUNCTION expert_security.quote_error(p_user uuid, p_listing bigint)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.listings; reason text;
BEGIN
  SELECT * INTO l FROM public.listings WHERE id=p_listing;
  IF l.id IS NULL OR l.status<>'open' THEN RETURN 'İlan teklif almaya açık değil.'; END IF;
  IF l.owner=p_user THEN RETURN 'Kendi ilanınıza teklif veremezsiniz.'; END IF;
  reason:=expert_security.category_error(p_user,l.category);
  IF reason IS NOT NULL THEN RETURN reason; END IF;
  IF public.is_blocked(p_user,l.owner) THEN RETURN 'Engelleme nedeniyle bu işlem yapılamıyor.'; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION expert_security.can_quote_listing(p_listing bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND expert_security.quote_error(auth.uid(),p_listing) IS NULL;
$$;
CREATE OR REPLACE FUNCTION public.quote_eligibility(p_listing_id bigint)
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
  SELECT CASE WHEN expert_security.can_quote_listing(p_listing_id) THEN NULL::text
    ELSE 'Bu ilan için geçerli uzman/kategori onayınız yok, ilan kapalı veya erişiminiz kısıtlı.' END;
$$;

-- Definer avoids listings -> quotes -> listings RLS recursion. Historical quote access
-- is separate from permission to submit/select a NEW quote. Partner NULL means all.
CREATE OR REPLACE FUNCTION expert_security.can_read_listing(p_listing bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(
  SELECT 1 FROM public.listings l WHERE l.id=p_listing AND (
    l.owner=auth.uid() OR public.is_admin()
    OR (NOT public.is_blocked(auth.uid(),l.owner) AND (
      expert_security.quote_error(auth.uid(),l.id) IS NULL
      OR EXISTS(SELECT 1 FROM public.quotes q WHERE q.listing_id=l.id AND q.pro=auth.uid())
    ))
    OR EXISTS(SELECT 1 FROM public.partner_members pm JOIN public.partners p ON p.id=pm.partner_id
      WHERE pm.user_id=auth.uid() AND pm.status='active' AND p.status='active'
      AND p.id=l.partner_id AND (p.service_categories IS NULL OR l.category=ANY(p.service_categories)))
  ));
$$;
CREATE OR REPLACE FUNCTION public.expert_job_pool()
RETURNS SETOF public.listings LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 SELECT l.* FROM public.listings l WHERE l.status='open' AND expert_security.can_quote_listing(l.id)
 ORDER BY l.created_at DESC LIMIT 100;
$$;

CREATE OR REPLACE FUNCTION expert_security.authorizations()
RETURNS TABLE(user_id uuid, categories text[]) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT v.user_id,array_agg(DISTINCT v.category ORDER BY v.category)
 FROM public.professional_verifications v
 WHERE auth.uid() IS NOT NULL AND v.status='approved'
   AND v.verification_type IN ('vocational','diploma','certificate')
   AND expert_security.category_error(v.user_id,v.category) IS NULL
   AND NOT public.is_blocked(auth.uid(),v.user_id)
 GROUP BY v.user_id;
$$;
CREATE OR REPLACE FUNCTION public.expert_authorizations()
RETURNS TABLE(user_id uuid,categories text[]) LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 SELECT * FROM expert_security.authorizations();
$$;

ALTER POLICY "teklif ekleme" ON public.quotes
 WITH CHECK (pro=(SELECT auth.uid()) AND expert_security.can_quote_listing(listing_id));
ALTER POLICY "ilan okuma" ON public.listings USING (expert_security.can_read_listing(id));
ALTER POLICY "bildirim okuma" ON public.notifications USING (
 user_id=(SELECT auth.uid()) AND (type<>'nearby_job' OR expert_security.can_quote_listing(listing_id)));
CREATE OR REPLACE FUNCTION public.can_view_listing_photo(p_listing_id bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 SELECT public.is_active_user() AND expert_security.can_read_listing(p_listing_id);
$$;
ALTER POLICY "ilan fotografi okuma" ON public.listing_photos
 USING (public.can_view_listing_photo(listing_id));
ALTER POLICY "ilan fotograflari oku" ON storage.objects USING (
 bucket_id='listing-photos' AND EXISTS(SELECT 1 FROM public.listings l
 WHERE (storage.foldername(name))[1]=l.owner::text
 AND (storage.foldername(name))[2]=l.id::text AND public.can_view_listing_photo(l.id)));

CREATE OR REPLACE FUNCTION public.notify_nearby_job()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.notifications(user_id,type,title,body,listing_id,actor_id)
 SELECT p.id,'nearby_job','Bölgende yeni iş',
 coalesce(array_to_string(new.problems,', '),'Yeni hizmet talebi')||' · '||coalesce(new.district,new.city),new.id,new.owner
 FROM public.profiles p
 WHERE expert_security.quote_error(p.id,new.id) IS NULL
 AND coalesce(p.service_city,'')<>'' AND lower(trim(p.service_city))=lower(trim(new.city))
 AND (coalesce(cardinality(p.service_districts),0)=0 OR EXISTS(
 SELECT 1 FROM unnest(p.service_districts) d WHERE lower(trim(d))=lower(trim(new.district))));
 RETURN new;
END $$;

-- Review locks profile first, like selection, serializing revocation with new selection.
CREATE OR REPLACE FUNCTION public.admin_review_verification(p_verification_id uuid,p_status text,p_note text DEFAULT NULL)
RETURNS public.professional_verifications LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.professional_verifications; target uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_admin() THEN RAISE EXCEPTION 'Yetkisiz' USING ERRCODE='42501'; END IF;
 IF p_status IS NULL OR p_status NOT IN ('approved','rejected','expired') THEN RAISE EXCEPTION 'Geçersiz durum'; END IF;
 SELECT user_id INTO target FROM public.professional_verifications WHERE id=p_verification_id;
 IF target IS NULL THEN RAISE EXCEPTION 'Doğrulama bulunamadı'; END IF;
 PERFORM 1 FROM public.profiles WHERE id=target FOR UPDATE;
 SELECT * INTO v FROM public.professional_verifications WHERE id=p_verification_id FOR UPDATE;
 IF NOT (v.status='pending' OR (v.status='approved' AND p_status IN ('rejected','expired'))) THEN
   RAISE EXCEPTION 'Bu doğrulama bu duruma geçirilemez';
 END IF;
 IF p_status='approved' THEN
   IF v.expires_at IS NOT NULL AND v.expires_at<=statement_timestamp() THEN RAISE EXCEPTION 'Belgenin süresi dolmuş'; END IF;
   IF v.verification_type IN ('vocational','diploma','certificate') AND NOT (v.category=ANY(ARRAY['boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi','elektronik','lastik','oto','temizlik','nakliyat','bahce','ozelders','guzellik','kucukisler','evcilhayvan','diger'])) THEN
     RAISE EXCEPTION 'Mesleki belge için geçerli bir hizmet kategorisi gerekli';
   END IF;
 END IF;
 UPDATE public.professional_verifications SET status=p_status,review_note=nullif(trim(coalesce(p_note,'')),''),
 reviewed_at=statement_timestamp(),reviewed_by=auth.uid() WHERE id=v.id RETURNING * INTO v;
 -- Compatibility-only badge cache; runtime authorization always reads documents.
 UPDATE public.profiles p SET
 identity_verified=EXISTS(SELECT 1 FROM public.professional_verifications x WHERE x.user_id=target AND x.verification_type='identity' AND x.status='approved' AND (x.expires_at IS NULL OR x.expires_at>statement_timestamp())),
 vocational_verified=EXISTS(SELECT 1 FROM public.professional_verifications x WHERE x.user_id=target AND x.verification_type IN ('vocational','diploma','certificate') AND x.status='approved' AND (x.expires_at IS NULL OR x.expires_at>statement_timestamp())),
 business_verified=EXISTS(SELECT 1 FROM public.professional_verifications x WHERE x.user_id=target AND x.verification_type='business' AND x.status='approved' AND (x.expires_at IS NULL OR x.expires_at>statement_timestamp()))
 WHERE p.id=target;
 RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.choose_quote_with_payment(p_listing_id bigint, p_quote_id bigint, p_method text, p_deposit_percent smallint DEFAULT NULL::smallint, p_promotion_id uuid DEFAULT NULL::uuid)
 RETURNS listings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  result public.listings;
  v_l public.listings%rowtype;
  v_q public.quotes%rowtype;
  v_p public.promotions%rowtype;
  v_used integer;
  v_total integer;
  v_prior integer;
  v_discount numeric(12,2):=0;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Aktif oturum gerekli';
  end if;

  select * into v_l from public.listings
  where id=p_listing_id and owner=v_uid and status='open'
  for update;
  if v_l.id is null then
    raise exception 'İlan açık değil veya sana ait değil';
  end if;

  select * into v_q from public.quotes
  where id=p_quote_id and listing_id=p_listing_id;
  if v_q.id is null or v_q.pro=v_l.owner or public.is_blocked(v_uid,v_q.pro) then
    raise exception 'Bu teklif seçilemez';
  end if;

  -- Serialize account/verification revocation with this atomic selection.
  perform 1 from public.profiles where id=v_q.pro for share;
  perform 1 from public.professional_verifications where user_id=v_q.pro for share;
  if expert_security.quote_error(v_q.pro,p_listing_id) is not null then
    raise exception '%', expert_security.quote_error(v_q.pro,p_listing_id) using errcode='42501';
  end if;

  if p_method is null or not (p_method=any(v_q.payment_methods)) then
    raise exception 'Ödeme yöntemi uzman tarafından kabul edilmiyor';
  end if;
  if p_method='deposit_cash' then
    if p_deposit_percent is null or p_deposit_percent is distinct from v_q.deposit_percent then
      raise exception 'Ön ödeme oranı geçersiz';
    end if;
  else
    p_deposit_percent:=null;
  end if;

  if p_promotion_id is not null then
    select * into v_p from public.promotions where id=p_promotion_id for update;
    if v_p.id is null or v_p.status<>'active' or v_p.starts_at>now()
       or (v_p.ends_at is not null and v_p.ends_at<now()) then
      raise exception 'Promosyon geçerli değil';
    end if;
    if v_q.price < v_p.min_amount then raise exception 'Promosyon için tutar yetersiz'; end if;
    if cardinality(v_p.categories)>0 and not (v_l.category=any(v_p.categories)) then raise exception 'Promosyon bu hizmette geçerli değil'; end if;
    if cardinality(v_p.cities)>0 and not (v_l.city=any(v_p.cities)) then raise exception 'Promosyon bu şehirde geçerli değil'; end if;
    if v_p.partner_id is not null and v_l.partner_id is distinct from v_p.partner_id then raise exception 'Promosyon bu partner işi için geçerli değil'; end if;

    select count(*) into v_used from public.promo_redemptions where promotion_id=v_p.id and user_id=v_uid;
    if v_p.per_user_limit is not null and v_used>=v_p.per_user_limit then raise exception 'Bu promosyonu daha önce kullandın'; end if;
    select count(*) into v_total from public.promo_redemptions where promotion_id=v_p.id;
    if v_p.total_limit is not null and v_total>=v_p.total_limit then raise exception 'Kampanya kullanım limiti doldu'; end if;
    if v_p.new_users_only then
      select count(*) into v_prior from public.listings where owner=v_uid and id<>p_listing_id and status in ('chosen','done');
      if v_prior>0 then raise exception 'Bu kampanya yalnızca ilk iş için geçerli'; end if;
    end if;

    v_discount:=case when v_p.discount_type='percent'
      then round((v_q.price*v_p.discount_value/100.0)::numeric,2)
      else v_p.discount_value end;
    if v_p.max_discount is not null then v_discount:=least(v_discount,v_p.max_discount); end if;
    v_discount:=greatest(0,least(v_discount,v_q.price));
  end if;

  update public.listings
  set status='chosen',chosen_quote=p_quote_id
  where id=p_listing_id
  returning * into result;

  insert into public.listing_payment_choices(
    listing_id,quote_id,customer_id,method,deposit_percent,promotion_id,discount_amount
  ) values (
    p_listing_id,p_quote_id,v_uid,p_method,p_deposit_percent,p_promotion_id,v_discount
  );

  if p_promotion_id is not null then
    insert into public.promo_redemptions(promotion_id,user_id,listing_id,quote_id,discount_amount)
    values(p_promotion_id,v_uid,p_listing_id,p_quote_id,v_discount);
  end if;

  insert into public.notifications(user_id,type,title,body,listing_id,actor_id)
  values(v_q.pro,'chosen','Teklifin seçildi','Müşteri teklifini seçti. Artık mesajlaşabilirsiniz.',p_listing_id,v_uid);

  return result;
end;
$function$
;

-- Close the unused selection path; frontend uses choose_quote_with_payment exclusively.
REVOKE ALL ON FUNCTION public.choose_quote(bigint,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.notify_nearby_job() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA expert_security FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION expert_security.can_quote_listing(bigint),expert_security.can_read_listing(bigint),expert_security.authorizations() TO authenticated;
REVOKE ALL ON FUNCTION public.expert_authorizations(),public.expert_job_pool(),public.quote_eligibility(bigint),public.can_view_listing_photo(bigint),public.admin_review_verification(uuid,text,text),public.choose_quote_with_payment(bigint,bigint,text,smallint,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.expert_authorizations(),public.expert_job_pool(),public.quote_eligibility(bigint),public.can_view_listing_photo(bigint),public.admin_review_verification(uuid,text,text),public.choose_quote_with_payment(bigint,bigint,text,smallint,uuid) TO authenticated;
-- RLS does not protect TRUNCATE; unnecessary DDL-like client rights on affected tables.
REVOKE TRUNCATE,TRIGGER,REFERENCES ON public.profiles,public.listings,public.quotes,public.professional_verifications FROM anon,authenticated;
CREATE INDEX IF NOT EXISTS verification_authorization_idx ON public.professional_verifications(user_id,category,verification_type) WHERE status='approved';
CREATE INDEX IF NOT EXISTS verification_reviewer_idx ON public.professional_verifications(reviewed_by);
NOTIFY pgrst,'reload schema';
