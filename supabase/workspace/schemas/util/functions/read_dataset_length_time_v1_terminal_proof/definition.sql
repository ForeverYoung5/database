CREATE OR REPLACE FUNCTION "util"."read_dataset_length_time_v1_terminal_proof"("p_actor_user_id" "uuid", "p_plan" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_expected jsonb := coalesce(p_plan->'expected', '{}'::jsonb);
  v_plan_sha256 text := p_plan->>'plan_sha256';
  v_row_audits jsonb;
  v_readback_rows jsonb := '[]'::jsonb;
  v_action jsonb;
  v_row jsonb;
  v_plan_summary_id bigint;
  v_batch_summary_id bigint;
  v_drift_count integer := 0;
  v_desired_sha256 text;
  v_expected_text text;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action_id', audit.payload->>'action_id',
      'table', audit.target_table,
      'id', audit.target_id,
      'version', audit.target_version,
      'after_sha256', audit.payload->>'after_sha256') order by audit.id), '[]'::jsonb)
    into v_row_audits
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_length_time_v1_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'row';

  select audit.id into v_batch_summary_id
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_length_time_v1_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'plan'
  order by audit.id desc limit 1;

  select audit.id into v_plan_summary_id
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_length_time_v1_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'plan_summary'
  order by audit.id desc limit 1;

  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_row := null;
    select jsonb_build_object(
        'table', 'processes', 'id', process.id, 'version', btrim(process.version::text),
        'observed_sha256', private.dataset_alias_v2_payload_sha256(process.json_ordered::jsonb),
        'functional_unit_text',
          process.json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}')
      into v_row
    from public.processes as process
    where process.id = (v_action->>'id')::uuid
      and btrim(process.version::text) = v_action->>'version'
      and process.user_id = p_actor_user_id
      and process.state_code = 0;
    if v_row is not null then
      -- The reported observation is the live row, never the plan's claim: a drifted payload or a
      -- drifted functional-unit text is reported as it actually is, and it also marks the proof as
      -- not applied. No text action exists in this profile, so the expectation is the plan's own
      -- before image.
      v_desired_sha256 := v_action->>'desired_sha256';
      v_expected_text := v_action #>> '{expected_json_ordered,processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}';
      if (v_row->>'observed_sha256') is distinct from v_desired_sha256
        or (v_row->>'functional_unit_text') is distinct from v_expected_text then
        v_drift_count := v_drift_count + 1;
      end if;
      v_readback_rows := v_readback_rows || jsonb_build_array(v_row);
    end if;
  end loop;

  return jsonb_build_object(
    -- Applied only when every claimed row is observed exactly at its desired image with its expected
    -- functional-unit text; a drifted observation can never be labelled applied.
    'status', case
      when v_drift_count = 0
        and jsonb_array_length(v_readback_rows) = coalesce((v_expected->>'action_count')::integer, -1)
      then 'applied' else 'failed' end,
    'plan_sha256', v_plan_sha256,
    'counts', v_expected,
    'audit', jsonb_build_object(
      'batch_count', coalesce((v_expected->>'batch_count')::integer, 1),
      'row_audit_count', coalesce(jsonb_array_length(v_row_audits), 0),
      'plan_summary_audit_id', v_plan_summary_id,
      'batch_summary_audit_id', v_batch_summary_id,
      'row_audits', coalesce(v_row_audits, '[]'::jsonb)),
    'readback', jsonb_build_object(
      'row_count', jsonb_array_length(v_readback_rows),
      'exchange_count', coalesce((v_expected->>'exchange_count')::integer, 0),
      'rows', v_readback_rows));
end
$$;

ALTER FUNCTION "util"."read_dataset_length_time_v1_terminal_proof"("p_actor_user_id" "uuid", "p_plan" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "util"."read_dataset_length_time_v1_terminal_proof"("p_actor_user_id" "uuid", "p_plan" "jsonb") FROM PUBLIC;
