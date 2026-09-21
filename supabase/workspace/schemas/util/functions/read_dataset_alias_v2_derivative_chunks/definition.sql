CREATE OR REPLACE FUNCTION "util"."read_dataset_alias_v2_derivative_chunks"("p_actor_user_id" "uuid", "p_request_id" "uuid", "p_plan_sha256" "text", "p_targets" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_chunks jsonb;
  v_chunk jsonb;
  v_proof jsonb;
  v_chunk_proofs jsonb := '[]'::jsonb;
  v_target_count integer := 0;
  v_flow_count integer := 0;
  v_process_count integer := 0;
  v_completed_count integer := 0;
  v_nonterminal_count integer := 0;
  v_failed_count integer := 0;
  v_invalid_proof_count integer := 0;
  v_all_terminal boolean := true;
  v_any_failed boolean := false;
begin
  v_chunks := private.dataset_alias_v2_derivative_chunks(p_request_id, p_plan_sha256, p_targets);

  for v_chunk in select * from jsonb_array_elements(v_chunks) as chunk loop
    v_proof := util.read_dataset_derivative_rebuild_batch_any(
      p_actor_user_id,
      (v_chunk->>'batch_id')::uuid
    );
    v_target_count := v_target_count + coalesce((v_proof->>'target_count')::integer, 0);
    v_flow_count := v_flow_count + coalesce((v_proof->>'flow_count')::integer, 0);
    v_process_count := v_process_count + coalesce((v_proof->>'process_count')::integer, 0);
    v_completed_count := v_completed_count + coalesce((v_proof->>'completed_count')::integer, 0);
    v_nonterminal_count := v_nonterminal_count + coalesce((v_proof->>'nonterminal_count')::integer, 0);
    v_failed_count := v_failed_count + coalesce((v_proof->>'failed_count')::integer, 0);
    v_invalid_proof_count := v_invalid_proof_count + coalesce((v_proof->>'invalid_proof_count')::integer, 0);
    if coalesce((v_proof->>'causal_terminal_proof')::boolean, false) is not true then
      v_all_terminal := false;
    end if;
    if (v_proof->>'status') = 'failed' then
      v_any_failed := true;
    end if;
    v_chunk_proofs := v_chunk_proofs || jsonb_build_array(jsonb_build_object(
      'ordinal', (v_chunk->>'ordinal')::integer,
      'batch_id', v_chunk->>'batch_id',
      'status', v_proof->>'status',
      'code', v_proof->>'code',
      'target_count', coalesce((v_proof->>'target_count')::integer, 0),
      'completed_count', coalesce((v_proof->>'completed_count')::integer, 0),
      'nonterminal_count', coalesce((v_proof->>'nonterminal_count')::integer, 0),
      'failed_count', coalesce((v_proof->>'failed_count')::integer, 0),
      'causal_terminal_proof', coalesce((v_proof->>'causal_terminal_proof')::boolean, false)));
  end loop;

  return jsonb_build_object(
    'schema_version', 'dataset-alias-v2-derivative-orchestration.v1',
    'request_id', p_request_id,
    'chunk_count', jsonb_array_length(v_chunks),
    'chunk_target_bound', 50,
    'target_count', v_target_count,
    'approved_target_count', jsonb_array_length(coalesce(p_targets, '[]'::jsonb)),
    'membership_exact', v_target_count = jsonb_array_length(coalesce(p_targets, '[]'::jsonb)),
    'flow_count', v_flow_count,
    'process_count', v_process_count,
    'completed_count', v_completed_count,
    'nonterminal_count', v_nonterminal_count,
    'failed_count', v_failed_count,
    'invalid_proof_count', v_invalid_proof_count,
    'causal_terminal_proof', v_all_terminal and v_target_count = jsonb_array_length(coalesce(p_targets, '[]'::jsonb)),
    'status', case
      when v_any_failed then 'failed'
      when v_all_terminal and v_target_count = jsonb_array_length(coalesce(p_targets, '[]'::jsonb)) then 'completed'
      else 'pending'
    end,
    'chunks', v_chunk_proofs);
end
$$;

ALTER FUNCTION "util"."read_dataset_alias_v2_derivative_chunks"("p_actor_user_id" "uuid", "p_request_id" "uuid", "p_plan_sha256" "text", "p_targets" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "util"."read_dataset_alias_v2_derivative_chunks"("p_actor_user_id" "uuid", "p_request_id" "uuid", "p_plan_sha256" "text", "p_targets" "jsonb") FROM PUBLIC;
