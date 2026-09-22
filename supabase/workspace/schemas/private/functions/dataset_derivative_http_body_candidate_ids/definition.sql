CREATE OR REPLACE FUNCTION "private"."dataset_derivative_http_body_candidate_ids"("p_body" "bytea") RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_body jsonb;
  v_ids text[];
begin
  if p_body is null then
    return array[]::text[];
  end if;
  v_body := pg_catalog.convert_from(p_body, 'UTF8')::jsonb;
  if jsonb_typeof(v_body) = 'object' then
    select coalesce(array_agg(candidate.value), array[]::text[])
    into v_ids
    from (
      select v_body #>> '{record,id}' as value
      union all
      select v_body #>> '{old_record,id}'
    ) as candidate
    where candidate.value is not null;
    return v_ids;
  end if;
  if jsonb_typeof(v_body) = 'array' then
    select coalesce(array_agg(distinct job.value->>'id'), array[]::text[])
    into v_ids
    from jsonb_array_elements(v_body) as job(value)
    where job.value->>'id' is not null;
    return v_ids;
  end if;
  return array[]::text[];
exception
  when others then
    return array[]::text[];
end;
$$;

ALTER FUNCTION "private"."dataset_derivative_http_body_candidate_ids"("p_body" "bytea") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_derivative_http_body_candidate_ids"("p_body" "bytea") FROM PUBLIC;
