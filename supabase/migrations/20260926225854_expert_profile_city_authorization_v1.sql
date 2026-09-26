-- Sprint 1: structured expert profile, category/city authorization and district priority.
-- This is a forward migration over the verified LIVE schema on 2026-09-27.
-- Existing services, quotes, selected jobs, messages and payment rows are untouched.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS service_categories text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS expert_status text NOT NULL DEFAULT 'not_started';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='profiles_expert_status_check' AND conrelid='public.profiles'::regclass) THEN
    ALTER TABLE public.profiles ADD CONSTRAINT profiles_expert_status_check
      CHECK (expert_status IN ('not_started','active')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='profiles_service_categories_check' AND conrelid='public.profiles'::regclass) THEN
    ALTER TABLE public.profiles ADD CONSTRAINT profiles_service_categories_check
      CHECK (service_categories <@ ARRAY['boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi','elektronik','lastik','oto','temizlik','nakliyat','bahce','ozelders','guzellik','kucukisler','evcilhayvan','diger']::text[])
      NOT VALID;
  END IF;
END $$;
ALTER TABLE public.profiles VALIDATE CONSTRAINT profiles_expert_status_check;
ALTER TABLE public.profiles VALIDATE CONSTRAINT profiles_service_categories_check;

CREATE OR REPLACE FUNCTION expert_security.profile_is_complete(p public.profiles)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p.account_status='active'
    AND p.expert_status='active'
    AND cardinality(p.service_categories)>0
    AND length(trim(p.service_city))>0
    AND length(trim(p.name))>=2
    AND length(trim(p.title))>=3
    AND length(trim(p.bio))>=10;
$$;

CREATE OR REPLACE FUNCTION public.sync_expert_profile_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.expert_status := CASE WHEN NEW.account_status='active'
    AND cardinality(NEW.service_categories)>0
    AND length(trim(NEW.service_city))>0
    AND length(trim(NEW.name))>=2
    AND length(trim(NEW.title))>=3
    AND length(trim(NEW.bio))>=10
    THEN 'active' ELSE 'not_started' END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS profiles_sync_expert_status ON public.profiles;
CREATE TRIGGER profiles_sync_expert_status
BEFORE INSERT OR UPDATE OF account_status,service_categories,service_city,name,title,bio ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.sync_expert_profile_status();

CREATE OR REPLACE FUNCTION public.save_expert_profile(
  p_categories text[], p_city text, p_districts text[], p_title text, p_bio text
) RETURNS public.profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_uid uuid:=auth.uid(); v_categories text[]; v_districts text[]; result public.profiles;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Oturum gerekli' USING ERRCODE='42501'; END IF;
  SELECT coalesce(array_agg(DISTINCT trim(x) ORDER BY trim(x)),'{}'::text[])
    INTO v_categories FROM unnest(coalesce(p_categories,'{}'::text[])) x WHERE trim(x)<>'';
  SELECT coalesce(array_agg(DISTINCT trim(x) ORDER BY trim(x)),'{}'::text[])
    INTO v_districts FROM unnest(coalesce(p_districts,'{}'::text[])) x WHERE trim(x)<>'';
  IF cardinality(v_categories)=0 OR NOT (v_categories <@ ARRAY['boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi','elektronik','lastik','oto','temizlik','nakliyat','bahce','ozelders','guzellik','kucukisler','evcilhayvan','diger']::text[]) THEN
    RAISE EXCEPTION 'En az bir geçerli hizmet kategorisi seçmelisin';
  END IF;
  IF length(trim(coalesce(p_city,'')))=0 THEN RAISE EXCEPTION 'Hizmet verdiğin şehri seçmelisin'; END IF;
  IF length(trim(coalesce(p_title,'')))<3 THEN RAISE EXCEPTION 'Uzmanlık başlığını yazmalısın'; END IF;
  IF length(trim(coalesce(p_bio,'')))<10 THEN RAISE EXCEPTION 'Kısa açıklama en az 10 karakter olmalı'; END IF;
  UPDATE public.profiles SET service_categories=v_categories,service_city=trim(p_city),
    service_districts=v_districts,title=trim(p_title),bio=trim(p_bio)
  WHERE id=v_uid AND account_status='active' RETURNING * INTO result;
  IF result.id IS NULL THEN RAISE EXCEPTION 'Hesabınız şu anda uzman profili oluşturmaya uygun değil' USING ERRCODE='42501'; END IF;
  RETURN result;
END $$;

-- The legacy services field and verification badges remain UX data, never authorization.
CREATE OR REPLACE FUNCTION expert_security.category_error(p_user uuid,p_category text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.profiles;
BEGIN
  SELECT * INTO p FROM public.profiles WHERE id=p_user;
  IF p.id IS NULL OR p.account_status<>'active' THEN RETURN 'Hesabınız şu anda teklif vermeye uygun değil.'; END IF;
  IF p.expert_status<>'active' OR NOT expert_security.profile_is_complete(p) THEN RETURN 'Uzman profilini tamamlamalısın.'; END IF;
  IF p_category IS NULL OR NOT (p_category=ANY(p.service_categories)) THEN RETURN 'Bu hizmet kategorisinde teklif veremezsin.'; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION expert_security.opportunity_error(
  p_user uuid,p_owner uuid,p_category text,p_city text,p_status text
) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE reason text; expert_city text;
BEGIN
  IF p_status IS DISTINCT FROM 'open' THEN RETURN 'İlan teklif almaya açık değil.'; END IF;
  IF p_user IS NULL THEN RETURN 'Oturum gerekli.'; END IF;
  IF p_user=p_owner THEN RETURN 'Kendi ilanına teklif veremezsin.'; END IF;
  reason:=expert_security.category_error(p_user,p_category);
  IF reason IS NOT NULL THEN RETURN reason; END IF;
  SELECT service_city INTO expert_city FROM public.profiles WHERE id=p_user;
  IF lower(trim(expert_city)) IS DISTINCT FROM lower(trim(coalesce(p_city,''))) THEN RETURN 'Bu ilan hizmet verdiğin şehir dışında.'; END IF;
  IF public.is_blocked(p_user,p_owner) THEN RETURN 'Engelleme nedeniyle bu işlem yapılamıyor.'; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION expert_security.quote_error(p_user uuid,p_listing bigint)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.listings;
BEGIN
  SELECT * INTO l FROM public.listings WHERE id=p_listing;
  IF l.id IS NULL THEN RETURN 'İlan bulunamadı.'; END IF;
  RETURN expert_security.opportunity_error(p_user,l.owner,l.category,l.city,l.status);
END $$;

CREATE OR REPLACE FUNCTION public.quote_eligibility(p_listing_id bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN auth.uid() IS NULL THEN 'Oturum gerekli.'
    ELSE expert_security.quote_error(auth.uid(),p_listing_id) END;
$$;

CREATE OR REPLACE FUNCTION expert_security.authorizations()
RETURNS TABLE(user_id uuid,categories text[]) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id,p.service_categories FROM public.profiles p
  WHERE auth.uid() IS NOT NULL AND expert_security.profile_is_complete(p)
    AND p.id<>auth.uid() AND NOT public.is_blocked(auth.uid(),p.id);
$$;

CREATE OR REPLACE FUNCTION expert_security.can_receive_nearby_values(
  p_user uuid,p_owner uuid,p_category text,p_city text,p_district text,p_status text
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT expert_security.opportunity_error(p_user,p_owner,p_category,p_city,p_status) IS NULL
    AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=p_user AND
      (cardinality(p.service_districts)=0 OR EXISTS(
        SELECT 1 FROM unnest(p.service_districts) d WHERE lower(trim(d))=lower(trim(coalesce(p_district,''))))));
$$;
CREATE OR REPLACE FUNCTION expert_security.can_receive_nearby_job(p_listing bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.listings l WHERE l.id=p_listing
    AND expert_security.can_receive_nearby_values(auth.uid(),l.owner,l.category,l.city,l.district,l.status));
$$;

ALTER POLICY "bildirim okuma" ON public.notifications USING (
  user_id=(SELECT auth.uid()) AND (type<>'nearby_job' OR expert_security.can_receive_nearby_job(listing_id))
);

CREATE OR REPLACE FUNCTION public.notify_nearby_job()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.notifications(user_id,type,title,body,listing_id,actor_id)
  SELECT p.id,'nearby_job','Bölgende yeni iş',
    coalesce(array_to_string(NEW.problems,', '),'Yeni hizmet talebi')||' · '||coalesce(NEW.district,NEW.city),NEW.id,NEW.owner
  FROM public.profiles p
  WHERE expert_security.can_receive_nearby_values(p.id,NEW.owner,NEW.category,NEW.city,NEW.district,NEW.status);
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.save_expert_profile(text[],text,text[],text,text),public.quote_eligibility(bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_expert_profile(text[],text,text[],text,text),public.quote_eligibility(bigint) TO authenticated;
REVOKE ALL ON FUNCTION public.sync_expert_profile_status() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION expert_security.profile_is_complete(public.profiles),expert_security.opportunity_error(uuid,uuid,text,text,text),expert_security.quote_error(uuid,bigint),expert_security.can_receive_nearby_values(uuid,uuid,text,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION expert_security.can_receive_nearby_job(bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION expert_security.can_receive_nearby_job(bigint) TO authenticated;

CREATE INDEX IF NOT EXISTS profiles_expert_city_idx ON public.profiles(service_city) WHERE expert_status='active' AND account_status='active';
CREATE INDEX IF NOT EXISTS profiles_service_categories_gin_idx ON public.profiles USING gin(service_categories) WHERE expert_status='active' AND account_status='active';
NOTIFY pgrst,'reload schema';
