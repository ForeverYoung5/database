CREATE OR REPLACE FUNCTION "util"."admit_dataset_alias_v2_derivative_chunks"("p_actor_user_id" "uuid", "p_request_id" "uuid", "p_plan_sha256" "text", "p_operation_id" "text", "p_scope" "text", "p_targets" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_chunks jsonb;
  v_chunk jsonb;
  v_admitted jsonb := '[]'::jsonb;
  v_result jsonb;
  v_target_count integer := 0;
  v_flow_count integer := 0;
  v_process_count integer := 0;
  v_detail text;
  v_hint text;
begin
  v_chunks := private.dataset_alias_v2_derivative_chunks(p_request_id, p_plan_sha256, p_targets);

  -- The partition must be exact: every approved target exactly once, no chunk above the bound, no
  -- chunk without targets, distinct deterministic identities.
  if (select count(*) from jsonb_array_elements(v_chunks) as chunk
        where (chunk->>'target_count')::integer not between 1 and 50) <> 0
    or (select count(distinct chunk->>'batch_id') from jsonb_array_elements(v_chunks) as chunk)
      <> jsonb_array_length(v_chunks)
    or (select coalesce(sum((chunk->>'target_count')::integer), 0) from jsonb_array_elements(v_chunks) as chunk)
      <> jsonb_array_length(coalesce(p_targets, '[]'::jsonb)) then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_EXECUTION_DERIVATIVE_PARTITION_INVALID',
      'message', 'The derivative target partition is not an exact bounded cover of the approved targets');
  end if;

  -- The whole orchestration is one unit of work: a refusal raised inside this block takes every
  -- earlier chunk admission, its child rows and its audit effects down with it, so a caller can never
  -- observe a partially admitted target set.
  begin
    for v_chunk in select * from jsonb_array_elements(v_chunks) as chunk loop
      v_result := util.admit_dataset_derivative_rebuild_batch(
        p_actor_user_id,
        (v_chunk->>'batch_id')::uuid,
        p_plan_sha256,
        p_operation_id,
        p_scope,
        v_chunk->'targets'
      );
      if coalesce((v_result->>'ok')::boolean, false) is not true
        or (v_result->>'target_count')::integer is distinct from (v_chunk->>'target_count')::integer then
        raise exception using
          errcode = 'P0001',
          message = 'ALIAS_EXECUTION_DERIVATIVE_CHUNK_REFUSED',
          detail = 'A derivative sub-batch of the approved target set was refused',
          hint = jsonb_build_object(
            'ordinal', (v_chunk->>'ordinal')::integer,
            'batch_id', v_chunk->>'batch_id',
            'result', coalesce(v_result, '{}'::jsonb))::text;
      end if;
      v_target_count := v_target_count + (v_result->>'target_count')::integer;
      v_flow_count := v_flow_count + coalesce((v_result->>'flow_count')::integer, 0);
      v_process_count := v_process_count + coalesce((v_result->>'process_count')::integer, 0);
      v_admitted := v_admitted || jsonb_build_array(jsonb_build_object(
        'ordinal', (v_chunk->>'ordinal')::integer,
        'batch_id', v_chunk->>'batch_id',
        'target_count', (v_chunk->>'target_count')::integer,
        'summary_audit_id', v_result->>'summary_audit_id',
        'child_request_ids', coalesce(v_result->'child_request_ids', '[]'::jsonb)));
    end loop;
  exception
    when others then
      -- The subtransaction is already rolled back here, so every earlier chunk admission and its child
      -- rows are gone: the orchestration refuses as a whole. The owner's own refusal classes and any
      -- unexpected error both surface as this envelope, with the raising sqlstate kept for diagnosis —
      -- fail closed, never partially admitted.
      get stacked diagnostics v_detail = pg_exception_detail, v_hint = pg_exception_hint;
      return jsonb_build_object(
        'ok', false,
        'code', coalesce(nullif(sqlerrm, ''), 'ALIAS_EXECUTION_DERIVATIVE_CHUNK_REFUSED'),
        'sqlstate', sqlstate,
        'message', coalesce(nullif(v_detail, ''), 'A derivative sub-batch of the approved target set was refused'))
        || coalesce(nullif(v_hint, '')::jsonb, '{}'::jsonb);
  end;

  return jsonb_build_object(
    'ok', true,
    'code', 'ALIAS_EXECUTION_DERIVATIVE_CHUNKS_ADMITTED',
    'chunk_count', jsonb_array_length(v_chunks),
    'chunk_target_bound', 50,
    'target_count', v_target_count,
    'flow_count', v_flow_count,
    'process_count', v_process_count,
    'chunks', v_admitted);
end
$$;

ALTER FUNCTION "util"."admit_dataset_alias_v2_derivative_chunks"("p_actor_user_id" "uuid", "p_request_id" "uuid", "p_plan_sha256" "text", "p_operation_id" "text", "p_scope" "text", "p_targets" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "util"."admit_dataset_alias_v2_derivative_chunks"("p_actor_user_id" "uuid", "p_request_id" "uuid", "p_plan_sha256" "text", "p_operation_id" "text", "p_scope" "text", "p_targets" "jsonb") FROM PUBLIC;
