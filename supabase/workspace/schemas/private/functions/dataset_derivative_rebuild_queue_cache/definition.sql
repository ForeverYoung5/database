CREATE OR REPLACE FUNCTION "private"."dataset_derivative_rebuild_queue_cache"("p_targets" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  with queue_rows as (
    select
      request.id,
      request.ctid::text as ctid,
      private.dataset_derivative_http_body_candidate_ids(request.body) as ids
    from net.http_request_queue as request
    where request.url like '%/functions/v1/webhook_process_embedding_ft'
      or request.url like '%/functions/v1/webhook_flow_embedding_ft'
      or request.url like '%/functions/v1/embedding_ft'
  ),
  snapshot as (
    select jsonb_object_agg(queue_row.id::text, queue_row.ctid) as map
    from queue_rows as queue_row
  ),
  target_matches as (
    select
      matched.ordinal,
      jsonb_object_agg(distinct matched.id::text, true) as map
    from (
      select queue_row.id, target.ordinality as ordinal
      from queue_rows as queue_row
      cross join lateral unnest(queue_row.ids) as body_id(value)
      join lateral (
        select target.ordinality
        from jsonb_array_elements(p_targets) with ordinality as target(value, ordinality)
        where target.value->>'id' = body_id.value
      ) as target on true
    ) as matched
    group by matched.ordinal
  )
  select jsonb_build_object(
    'snapshot', coalesce((select snapshot.map from snapshot), '{}'::jsonb),
    'targets', coalesce(
      (select jsonb_object_agg(target_matches.ordinal::text, target_matches.map)
       from target_matches),
      '{}'::jsonb
    )
  )
$$;

ALTER FUNCTION "private"."dataset_derivative_rebuild_queue_cache"("p_targets" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_derivative_rebuild_queue_cache"("p_targets" "jsonb") FROM PUBLIC;
