-- Sprint 4: guest-safe expert preview for the listing draft.
-- Returns only public card fields; authorization/session/payment data is never exposed.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.preview_matching_experts(
  p_category text,
  p_city text,
  p_district text DEFAULT NULL
)
RETURNS TABLE(
  name text,
  title text,
  service_city text,
  rating numeric,
  jobs integer,
  identity_verified boolean,
  vocational_verified boolean,
  business_verified boolean,
  nearby boolean,
  total_count bigint,
  nearby_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH matched AS (
    SELECT
      p.name,
      p.title,
      p.service_city,
      s.rating,
      coalesce(s.jobs, 0)::integer AS jobs,
      coalesce(p.identity_verified, false) AS identity_verified,
      coalesce(p.vocational_verified, false) AS vocational_verified,
      coalesce(p.business_verified, false) AS business_verified,
      coalesce(nullif(trim(p_district), ''), '') <> ''
        AND EXISTS (
          SELECT 1
          FROM unnest(coalesce(p.service_districts, '{}'::text[])) AS d
          WHERE lower(trim(d)) = lower(trim(p_district))
        ) AS nearby
    FROM public.profiles AS p
    LEFT JOIN public.pro_stats AS s ON s.pro_id = p.id
    WHERE p_category = ANY (ARRAY[
      'boya','tesisat','elektrik','mobilya','fayans','klima','beyaz','kombi',
      'elektronik','lastik','oto','temizlik','nakliyat','bahce','ozelders',
      'guzellik','kucukisler','evcilhayvan','diger'
    ]::text[])
      AND length(trim(coalesce(p_city, ''))) > 0
      AND expert_security.category_error(p.id, p_category) IS NULL
      AND lower(trim(p.service_city)) = lower(trim(p_city))
  ), ranked AS (
    SELECT
      matched.*,
      count(*) OVER () AS total_count,
      count(*) FILTER (WHERE nearby) OVER () AS nearby_count
    FROM matched
  )
  SELECT
    ranked.name,
    ranked.title,
    ranked.service_city,
    ranked.rating,
    ranked.jobs,
    ranked.identity_verified,
    ranked.vocational_verified,
    ranked.business_verified,
    ranked.nearby,
    ranked.total_count,
    ranked.nearby_count
  FROM ranked
  ORDER BY ranked.nearby DESC, ranked.rating DESC NULLS LAST, ranked.jobs DESC, ranked.name
  LIMIT 12;
$$;

REVOKE ALL ON FUNCTION public.preview_matching_experts(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_matching_experts(text, text, text) TO anon, authenticated;

COMMENT ON FUNCTION public.preview_matching_experts(text, text, text) IS
  'Guest-safe active expert preview. Category and city are hard filters; district only ranks nearby experts.';

NOTIFY pgrst, 'reload schema';
