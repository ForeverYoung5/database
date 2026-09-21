CREATE OR REPLACE FUNCTION "api"."cmd_dataset_save_draft_guarded"("p_table" "text", "p_id" "uuid", "p_version" "text", "p_json_ordered" "jsonb", "p_expected_json_ordered" "jsonb", "p_model_id" "uuid" DEFAULT NULL::"uuid", "p_rule_verification" boolean DEFAULT NULL::boolean, "p_audit" "jsonb" DEFAULT '{}'::"jsonb", "p_model_version" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_current_row jsonb;
  v_current_content jsonb;
  v_owner_id uuid;
  v_state_code integer;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_expected_json_ordered is null
     or jsonb_typeof(p_expected_json_ordered) <> 'object' then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_BEFORE_CONTENT_REQUIRED',
      'status', 400,
      'message', 'A complete expected before-content JSON object is required'
    );
  end if;

  if p_table is null
     or p_table not in (
       'contacts',
       'sources',
       'unitgroups',
       'flowproperties',
       'flows',
       'processes',
       'lifecyclemodels'
     ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_DATASET_TABLE',
      'status', 400,
      'message', 'Unsupported dataset table'
    );
  end if;

  execute format(
    'select to_jsonb(t) from public.%I as t where t.id = $1 and t.version = $2 for update of t',
    p_table
  )
    into v_current_row
    using p_id, p_version;

  if v_current_row is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_NOT_FOUND',
      'status', 404,
      'message', 'Dataset not found'
    );
  end if;

  v_owner_id := nullif(v_current_row->>'user_id', '')::uuid;
  -- state_code is nullable, so an absent state stays unknown instead of defaulting to a draft:
  -- the guarded path is strictly owner state-0 and never infers draft authority from a NULL.
  v_state_code := (v_current_row->>'state_code')::integer;

  if v_owner_id is distinct from v_actor then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_OWNER_REQUIRED',
      'status', 403,
      'message', 'Only the dataset owner can save draft changes'
    );
  end if;

  if v_state_code >= 100 then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATA_ALREADY_PUBLISHED',
      'status', 403,
      'message', 'Published data cannot be edited through draft save',
      'details', jsonb_build_object(
        'state_code', v_state_code
      )
    );
  end if;

  if v_state_code >= 20 then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATA_UNDER_REVIEW',
      'status', 403,
      'message', 'Data is under review and cannot be modified',
      'details', jsonb_build_object(
        'state_code', 20,
        'review_state_code', v_state_code
      )
    );
  end if;

  if v_state_code is null or v_state_code <> 0 then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_STATE_NOT_DRAFT',
      'status', 403,
      'message', 'Only an owner draft can be saved through the guarded draft save'
    );
  end if;

  v_current_content := v_current_row->'json_ordered';

  if v_current_content is distinct from p_expected_json_ordered then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_BEFORE_CONTENT_CHANGED',
      'status', 409,
      'message', 'Draft content changed since it was read'
    );
  end if;

  return api.cmd_dataset_save_draft(
    p_table,
    p_id,
    p_version,
    p_json_ordered,
    p_model_id,
    p_rule_verification,
    p_audit,
    p_model_version
  );
end;
$_$;

ALTER FUNCTION "api"."cmd_dataset_save_draft_guarded"("p_table" "text", "p_id" "uuid", "p_version" "text", "p_json_ordered" "jsonb", "p_expected_json_ordered" "jsonb", "p_model_id" "uuid", "p_rule_verification" boolean, "p_audit" "jsonb", "p_model_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_dataset_save_draft_guarded"("p_table" "text", "p_id" "uuid", "p_version" "text", "p_json_ordered" "jsonb", "p_expected_json_ordered" "jsonb", "p_model_id" "uuid", "p_rule_verification" boolean, "p_audit" "jsonb", "p_model_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_dataset_save_draft_guarded"("p_table" "text", "p_id" "uuid", "p_version" "text", "p_json_ordered" "jsonb", "p_expected_json_ordered" "jsonb", "p_model_id" "uuid", "p_rule_verification" boolean, "p_audit" "jsonb", "p_model_version" "text") TO "authenticated";
