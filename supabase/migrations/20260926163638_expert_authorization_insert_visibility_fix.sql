-- INSERT ... RETURNING must authorize the new row without re-querying its snapshot.
ALTER POLICY "ilan okuma" ON public.listings USING (owner=(SELECT auth.uid()) OR expert_security.can_read_listing(id));

-- One opportunity predicate, usable both before/after insertion without snapshot lookup.
CREATE OR REPLACE FUNCTION expert_security.opportunity_error(p_user uuid,p_owner uuid,p_category text,p_status text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE reason text;
BEGIN
 IF p_status IS DISTINCT FROM 'open' THEN RETURN 'İlan teklif almaya açık değil.'; END IF;
 IF p_user=p_owner THEN RETURN 'Kendi ilanınıza teklif veremezsiniz.'; END IF;
 reason:=expert_security.category_error(p_user,p_category);
 IF reason IS NOT NULL THEN RETURN reason; END IF;
 IF public.is_blocked(p_user,p_owner) THEN RETURN 'Engelleme nedeniyle bu işlem yapılamıyor.'; END IF;
 RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION expert_security.quote_error(p_user uuid,p_listing bigint)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.listings;
BEGIN
 SELECT * INTO l FROM public.listings WHERE id=p_listing;
 RETURN expert_security.opportunity_error(p_user,l.owner,l.category,l.status);
END $$;
CREATE OR REPLACE FUNCTION public.notify_nearby_job()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.notifications(user_id,type,title,body,listing_id,actor_id)
 SELECT p.id,'nearby_job','Bölgende yeni iş',
 coalesce(array_to_string(new.problems,', '),'Yeni hizmet talebi')||' · '||coalesce(new.district,new.city),new.id,new.owner
 FROM public.profiles p
 WHERE expert_security.opportunity_error(p.id,new.owner,new.category,new.status) IS NULL
 AND coalesce(p.service_city,'')<>'' AND lower(trim(p.service_city))=lower(trim(new.city))
 AND (coalesce(cardinality(p.service_districts),0)=0 OR EXISTS(
 SELECT 1 FROM unnest(p.service_districts) d WHERE lower(trim(d))=lower(trim(new.district))));
 RETURN new;
END $$;
REVOKE ALL ON FUNCTION expert_security.opportunity_error(uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
