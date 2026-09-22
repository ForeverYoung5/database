CREATE OR REPLACE FUNCTION "util"."dataset_derivative_rebuild_http_body_matches"("p_body" "bytea", "p_id" "uuid", "p_version" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select util.dataset_derivative_rebuild_http_body_matches(
    p_body,
    'processes',
    p_id,
    p_version
  )
$$;

ALTER FUNCTION "util"."dataset_derivative_rebuild_http_body_matches"("p_body" "bytea", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "util"."dataset_derivative_rebuild_http_body_matches"("p_body" "bytea", "p_table" "text", "p_id" "uuid", "p_version" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_body jsonb;
begin
  if p_body is null
    or p_table is null
    or p_table not in ('flows', 'processes') then
    return false;
  end if;
  -- Conservative byte pre-filter: without the id bytes and without any `\u` escape prefix the
  -- decoded body cannot produce the id (only Unicode escapes can spell characters of a UUID text),
  -- so the parse below cannot return true. The bytea overload of pg_catalog.position takes the
  -- haystack first (unlike the `position(x in y)` text form), so p_body is the first argument;
  -- '\x5c75' is the two-byte `\u` sequence.
  --
  -- One deliberate difference, visible only to a caller that inspects the raw value: for an
  -- object-shaped body whose record.id is absent or JSON null (with neither the version nor the
  -- table comparison false) the pre-#689 body returned SQL NULL while this early return yields
  -- false. The true-set is identical - the early return fires only where the original could not
  -- return true - and every caller consumes this function in a positive filter context
  -- (DELETE/COUNT ... WHERE, WHERE EXISTS, LEFT JOIN ... ON) where NULL and false select the same
  -- rows; the batch suite pins the class and the call-site evidence is recorded with the #689
  -- review.
  if pg_catalog.position(p_body, pg_catalog.convert_to(p_id::text, 'UTF8')) = 0
    and pg_catalog.position(p_body, '\x5c75'::bytea) = 0 then
    return false;
  end if;
  v_body := pg_catalog.convert_from(p_body, 'UTF8')::jsonb;
  if jsonb_typeof(v_body) = 'object' then
    return v_body #>> '{record,id}' = p_id::text
      and btrim(v_body #>> '{record,version}') = p_version
      and coalesce(v_body->>'table', 'processes') = p_table;
  end if;

  if jsonb_typeof(v_body) = 'array' then
    return exists (
      select 1
      from jsonb_array_elements(v_body) as job(value)
      where job.value->>'id' = p_id::text
        and btrim(job.value->>'version') = p_version
        and job.value->>'schema' = 'public'
        and job.value->>'table' = p_table
        and job.value->>'embeddingColumn' = 'embedding_ft'
    );
  end if;

  return false;
exception
  when others then
    return false;
end;
$$;

ALTER FUNCTION "util"."dataset_derivative_rebuild_http_body_matches"("p_body" "bytea", "p_table" "text", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "util"."dataset_derivative_rebuild_http_body_matches"("p_body" "bytea", "p_id" "uuid", "p_version" "text") FROM PUBLIC;

REVOKE ALL ON FUNCTION "util"."dataset_derivative_rebuild_http_body_matches"("p_body" "bytea", "p_table" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;
