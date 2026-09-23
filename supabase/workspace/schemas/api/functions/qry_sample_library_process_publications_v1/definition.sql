CREATE OR REPLACE FUNCTION "api"."qry_sample_library_process_publications_v1"("p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) > 100 then
    return jsonb_build_object('ok', false, 'code', 'invalid_items', 'status', 400,
      'message', 'items must be an array with at most 100 Process versions');
  end if;

  select jsonb_build_object(
    'ok', true,
    'data', coalesce(jsonb_agg(jsonb_build_object(
      'id', requested.id,
      'version', requested.version,
      'published', publication.process_id is not null,
      'publishedAt', publication.published_at
    ) order by requested.ordinality), '[]'::jsonb)
  )
  into v_result
  from (
    select
      (item.value->>'id')::uuid as id,
      (item.value->>'version')::character(9) as version,
      item.ordinality
    from jsonb_array_elements(p_items) with ordinality as item(value, ordinality)
    where jsonb_typeof(item.value) = 'object'
      and item.value->>'id' ~* '^[0-9a-f-]{36}$'
      and item.value->>'version' ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
  ) requested
  left join private.sample_library_process_publications publication
    on publication.process_id = requested.id
   and publication.process_version = requested.version;

  return v_result;
end;
$_$;

ALTER FUNCTION "api"."qry_sample_library_process_publications_v1"("p_items" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_sample_library_process_publications_v1"("p_items" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_sample_library_process_publications_v1"("p_items" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."qry_sample_library_process_publications_v1"("p_items" "jsonb") TO "authenticated";
