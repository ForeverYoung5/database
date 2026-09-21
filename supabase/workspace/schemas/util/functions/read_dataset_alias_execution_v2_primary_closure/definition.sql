CREATE OR REPLACE FUNCTION "util"."read_dataset_alias_execution_v2_primary_closure"("p_actor" "uuid", "p_plan" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_action jsonb;
  v_found boolean;
  v_rows bigint := 0;
  v_claimed_rows bigint;
  v_exchange_count bigint;
begin
  if p_actor is null or jsonb_typeof(p_plan) is distinct from 'object' then
    return null;
  end if;
  v_claimed_rows := coalesce((p_plan #>> '{expected,action_count}')::bigint, -1);
  v_exchange_count := coalesce((p_plan #>> '{expected,exchange_count}')::bigint, -1);
  -- Fresh current readback: every claimed row must hold exactly the claimed desired payload now, for this
  -- actor, in the owner-draft state. The exact exchange set was proven under the lock by the batch
  -- executor; this readback re-verifies the committed rows rather than re-attesting a stored summary.
  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_found := null;
    if v_action->>'table' = 'flows' then
      select true into v_found
      from public.flows as flow
      where flow.id = (v_action->>'id')::uuid
        and flow.version = v_action->>'version'
        and flow.user_id = p_actor
        and flow.state_code = 0
        and flow.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    elsif v_action->>'table' = 'processes' then
      select true into v_found
      from public.processes as process
      where process.id = (v_action->>'id')::uuid
        and process.version = v_action->>'version'
        and process.user_id = p_actor
        and process.state_code = 0
        and process.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    else
      v_found := false;
    end if;
    if coalesce(v_found, false) then
      v_rows := v_rows + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'ok', v_rows = v_claimed_rows and v_claimed_rows >= 0,
    'live_closure_proof', v_rows = v_claimed_rows and v_claimed_rows >= 0,
    'row_count', v_rows,
    'claimed_row_count', v_claimed_rows,
    'exchange_count', v_exchange_count,
    'invalid_action_count', case when v_rows = v_claimed_rows then 0 else v_claimed_rows - v_rows end,
    'proof_sha256', util.dataset_alias_execution_v2_artifact_sha256(
      jsonb_build_object('actor', p_actor, 'rows', v_rows, 'claimed_rows', v_claimed_rows,
        'exchange_count', v_exchange_count, 'plan_sha256', p_plan->>'plan_sha256'))
  );
end
$$;

ALTER FUNCTION "util"."read_dataset_alias_execution_v2_primary_closure"("p_actor" "uuid", "p_plan" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "util"."read_dataset_alias_execution_v2_primary_closure"("p_actor" "uuid", "p_plan" "jsonb") FROM PUBLIC;
