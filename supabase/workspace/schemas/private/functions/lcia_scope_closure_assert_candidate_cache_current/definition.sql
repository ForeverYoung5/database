CREATE OR REPLACE FUNCTION "private"."lcia_scope_closure_assert_candidate_cache_current"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1
    from private.lcia_scope_closure_candidate_document_hashes as cache
    left join public.processes as process_row
      on process_row.id = cache.source_locator_id
     and btrim(process_row.version::text) = cache.dataset_version
    where cache.dataset_type = 'processes'
      and (
        process_row.id is null
        or process_row.state_code is distinct from 100
        or process_row.json_ordered is null
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'candidate_cache_not_current',
      detail = 'Run private.maintain_lcia_scope_closure_candidate_cache(integer, integer) until moreRemaining is false.';
  end if;
end;
$$;

ALTER FUNCTION "private"."lcia_scope_closure_assert_candidate_cache_current"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_scope_closure_assert_candidate_cache_current"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."lcia_scope_closure_assert_candidate_cache_current"() TO "api_internal_executor";
