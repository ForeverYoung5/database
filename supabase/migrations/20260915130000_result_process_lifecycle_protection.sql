-- Database #646 / workspace #1201: Result Process lifecycle protection.
--
-- Independent prerequisite slice for state 120. It makes an already-published Result
-- Process row immutable and closes the two SECURITY DEFINER downgrade paths that could
-- otherwise turn a Result back into an owner draft or reuse it as a version source.
--
-- Scope, stated exactly:
--   * OLD.state_code = 120 protection only. This migration does not govern INSERT, does
--     not create a state-120 row, and provides no publication admission or enablement.
--     No protected production command that creates a new state-120 Result exists yet;
--     that admission is a separate reviewed contract.
--   * No new role, grant, permission, endpoint, or visibility change. The future Result
--     publisher remains the existing platform data_product_manager.
--   * Ordinary 0 / 20 / 100 / 200 rows and every support table keep their behaviour.
--   * Privileged DDL is outside the threat model: an operator who already holds DDL
--     authority can drop this guard.
--   * This does not prevent a future authorized manager from publishing an equivalent
--     document under a different UUID through an audited command.

BEGIN;

-- 1) Lifecycle guard on public.processes.
--
-- OLD.state_code = 120 freezes every column except the four derivative fields that the
-- derivative pipeline owns. Two comparisons are required, and neither is sufficient
-- alone:
--   * json_ordered::text byte comparison, because jsonb normalization collapses key
--     order and whitespace and would hide an ordered-document edit; and
--   * to_jsonb comparison of the remaining columns, which protects every other column
--     including keys a future migration adds, without naming them.
-- The comparison subtracts only the four derivative keys from both sides, so the guard
-- never consults a caller-settable setting and has no bypass of any kind.
--
-- Trigger name is deliberately zzz_-prefixed and the trigger is BEFORE UPDATE, so it
-- runs after the alphabetically earlier BEFORE triggers that transform NEW
-- (processes_set_modified_at_trigger, review_dataset_content_guard_v1,
-- processes_json_sync_trigger). A later-running BEFORE trigger cannot therefore rewrite
-- NEW after this check. The only existing zzz_ trigger on this table
-- (zz_next_hybrid_public_process_candidate_v2) is AFTER and cannot mutate NEW.
create or replace function private.zzz_guard_process_result_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $guard$
declare
  v_derivatives constant text[] :=
    array['extracted_md', 'search_text', 'embedding_ft', 'embedding_ft_at'];
begin
  if tg_op = 'DELETE' then
    if old.state_code = 120 then
      raise exception using
        errcode = '55000',
        message = 'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
        detail = 'A published Result Process row cannot be deleted.';
    end if;
    return old;
  end if;

  if old.state_code = 120 then
    if new.json_ordered::text is distinct from old.json_ordered::text then
      raise exception using
        errcode = '55000',
        message = 'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
        detail = 'A published Result Process document cannot be modified.';
    end if;

    if (to_jsonb(new) - v_derivatives) is distinct from (to_jsonb(old) - v_derivatives)
    then
      raise exception using
        errcode = '55000',
        message = 'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
        detail = 'Only extracted_md, search_text, embedding_ft and embedding_ft_at may change on a published Result Process.';
    end if;
  end if;

  return new;
end;
$guard$;

alter function private.zzz_guard_process_result_lifecycle() owner to postgres;

-- Minimal ACL: a trigger function needs no caller EXECUTE privilege, so none is granted.
revoke all on function private.zzz_guard_process_result_lifecycle()
  from public, anon, authenticated, service_role;

comment on function private.zzz_guard_process_result_lifecycle() is
  'Freezes a published Result Process (OLD state_code 120) except its four derivative columns.';

drop trigger if exists zzz_guard_process_result_lifecycle on public.processes;
create trigger zzz_guard_process_result_lifecycle
  before update or delete on public.processes
  for each row execute function private.zzz_guard_process_result_lifecycle();

-- 2) Withdrawal may no longer downgrade a Result.
--
-- cmd_dataset_withdraw accepted 100..199 and wrote state 0, which is the actionable
-- 120 -> 0 path. The check sits after the state read and before the transition, so it
-- applies to every caller including the Data Product Manager: withdrawal is never a
-- manager bypass. Signature, owner, ACL and search_path are unchanged.
create or replace function api.cmd_dataset_withdraw(
  p_table text,
  p_id uuid,
  p_version text,
  p_reason text,
  p_audit jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
as $_$
declare
  v_actor uuid := auth.uid();
  v_current_row jsonb;
  v_owner_id uuid;
  v_state_code integer;
  v_updated_row jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_table not in ('sources', 'flows', 'processes') then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_DATASET_TABLE',
      'status', 400,
      'message', 'Only sources, flows, and processes can be withdrawn'
    );
  end if;

  if v_reason = '' or length(v_reason) > 4000 then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_WITHDRAW_REASON',
      'status', 400,
      'message', 'A non-empty withdrawal reason of at most 4000 characters is required'
    );
  end if;

  if jsonb_typeof(coalesce(p_audit, '{}'::jsonb)) <> 'object' then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_AUDIT_PAYLOAD',
      'status', 400,
      'message', 'Audit payload must be a JSON object'
    );
  end if;

  execute format(
    'select to_jsonb(t)
       from public.%I as t
      where t.id = $1
        and t.version = $2
      for update of t',
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
  v_state_code := coalesce((v_current_row->>'state_code')::integer, 0);

  if v_owner_id is distinct from v_actor then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_OWNER_REQUIRED',
      'status', 403,
      'message', 'Only the dataset owner can withdraw this dataset'
    );
  end if;

  if v_state_code = 0 then
    return jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'DATASET_ALREADY_DRAFT',
      'data', v_current_row
    );
  end if;

  -- A Result Process is withdrawn only through a role-preserving path that does not yet
  -- exist, so no caller may downgrade one to a draft. The check is deliberately scoped to
  -- this table so the command stays type-scoped; only processes can reach state 120.
  if p_table = 'processes' and v_state_code = 120 then
    return jsonb_build_object(
      'ok', false,
      'code', 'RESULT_WITHDRAW_REQUIRES_MIGRATION_PATH',
      'status', 403,
      'message', 'A published Result Process cannot be withdrawn to a draft',
      'details', jsonb_build_object(
        'state_code', v_state_code
      )
    );
  end if;

  if v_state_code < 100 or v_state_code >= 200 then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_WITHDRAW_REQUIRES_PUBLISHED_STATE',
      'status', 403,
      'message', 'Only public datasets in state 100 through 199 can be withdrawn',
      'details', jsonb_build_object(
        'state_code', v_state_code
      )
    );
  end if;

  execute format(
    'update public.%I as t
        set state_code = 0,
            rule_verification = false,
            modified_at = now()
      where t.id = $1
        and t.version = $2
    returning to_jsonb(t)',
    p_table
  )
    into v_updated_row
    using p_id, p_version;

  insert into private.command_audit_log (
    command,
    actor_user_id,
    target_table,
    target_id,
    target_version,
    payload
  )
  values (
    'cmd_dataset_withdraw',
    v_actor,
    p_table,
    p_id,
    p_version,
    coalesce(p_audit, '{}'::jsonb)
      || jsonb_build_object(
        'reason', v_reason,
        'from_state_code', v_state_code,
        'to_state_code', 0
      )
  );

  return jsonb_build_object(
    'ok', true,
    'changed', true,
    'data', v_updated_row
  );
end;
$_$;

alter function api.cmd_dataset_withdraw(text, uuid, text, text, jsonb) owner to postgres;
revoke all on function api.cmd_dataset_withdraw(text, uuid, text, text, jsonb) from public;
grant all on function api.cmd_dataset_withdraw(text, uuid, text, text, jsonb) to api_internal_executor;
grant all on function api.cmd_dataset_withdraw(text, uuid, text, text, jsonb) to authenticated;

-- 3) Version derivation may no longer source a Result.
--
-- The body below is the reviewed baseline reproduced verbatim apart from two insertions:
-- the v_source_state declaration and the Result isolation check. Every validation, both
-- Process and support INSERT branches, the response json_ordered field, every exception
-- code, and the audit payload are unchanged.
--
-- The insert path creates a NEW row at the table default state 0, which is the
-- "Result becomes an eligible owner draft" path. The source's own state is tested
-- directly, so the block holds even when no publication receipt exists, and the source
-- row is locked so its state cannot change between admission and the insert. The
-- established per-identity advisory lock is retained and no broad table lock is taken.
-- Non-process tables keep their previous behaviour exactly.
create or replace function api.cmd_dataset_create_version(
  p_table text,
  p_id uuid,
  p_source_version text,
  p_json_ordered jsonb,
  p_model_id uuid default null::uuid,
  p_rule_verification boolean default null::boolean,
  p_audit jsonb default '{}'::jsonb,
  p_model_version text default null::text
) returns jsonb
language plpgsql
security definer
set search_path = 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
as $_$
declare
  v_actor uuid := auth.uid();
  v_model_version text := nullif(btrim(coalesce(p_model_version, '')), '');
  v_root_key text;
  v_uri_slug text;
  v_source_exists boolean := false;
  v_source_state integer;
  v_source_version text := nullif(btrim(coalesce(p_source_version, '')), '');
  v_highest_version text;
  v_parts integer[];
  v_next_version text;
  v_next_uri text;
  v_payload jsonb;
  v_dataset jsonb;
  v_admin jsonb;
  v_pub jsonb;
  v_created_row jsonb;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  case p_table
    when 'contacts' then
      v_root_key := 'contactDataSet';
      v_uri_slug := 'contact';
    when 'sources' then
      v_root_key := 'sourceDataSet';
      v_uri_slug := 'source';
    when 'unitgroups' then
      v_root_key := 'unitGroupDataSet';
      v_uri_slug := 'unitgroup';
    when 'flowproperties' then
      v_root_key := 'flowPropertyDataSet';
      v_uri_slug := 'flowproperty';
    when 'flows' then
      v_root_key := 'flowDataSet';
      v_uri_slug := 'productFlow';
    when 'processes' then
      v_root_key := 'processDataSet';
      v_uri_slug := 'process';
    when 'lifecyclemodels' then
      return jsonb_build_object(
        'ok', false,
        'code', 'LIFECYCLEMODEL_BUNDLE_REQUIRED',
        'status', 400,
        'message', 'Lifecycle models must use bundle create-version commands'
      );
    else
      return jsonb_build_object(
        'ok', false,
        'code', 'INVALID_DATASET_TABLE',
        'status', 400,
        'message', 'Unsupported dataset table'
      );
  end case;

  if p_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_ID_REQUIRED',
      'status', 400,
      'message', 'id is required'
    );
  end if;

  if p_json_ordered is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'JSON_ORDERED_REQUIRED',
      'status', 400,
      'message', 'jsonOrdered is required'
    );
  end if;

  if v_source_version is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'DATASET_SOURCE_VERSION_REQUIRED',
      'status', 400,
      'message', 'sourceVersion is required'
    );
  end if;

  if p_table <> 'processes' and p_model_id is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'MODEL_ID_NOT_ALLOWED',
      'status', 400,
      'message', 'modelId is only allowed for process dataset version creation'
    );
  end if;

  if p_table <> 'processes' and v_model_version is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'MODEL_VERSION_NOT_ALLOWED',
      'status', 400,
      'message', 'modelVersion is only allowed for process dataset version creation'
    );
  end if;

  if v_model_version is not null and p_model_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'MODEL_ID_REQUIRED_FOR_MODEL_VERSION',
      'status', 400,
      'message', 'modelId is required when modelVersion is provided'
    );
  end if;

  if v_model_version is not null
     and v_model_version !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$' then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_MODEL_VERSION',
      'status', 400,
      'message', 'modelVersion must use NN.NN.NNN format'
    );
  end if;

  perform set_config('lock_timeout', '2s', true);
  perform set_config('statement_timeout', '8s', true);

  begin
    perform pg_advisory_xact_lock(
      hashtext('cmd_dataset_create_version:' || p_table),
      hashtext(p_id::text)
    );

    execute format(
      'select exists(
         select 1
           from public.%I d
          where d.id = $1
            and d.version = $2
            and (
              d.state_code >= 100
              or d.user_id = $3
              or exists (
                select 1
                  from private.roles r
                 where r.team_id = d.team_id
                   and r.user_id = $3
                   and r.role::text = any(array[''admin'', ''member'', ''owner''])
              )
            )
       )',
      p_table
    )
      into v_source_exists
      using p_id, v_source_version, v_actor;

    if not v_source_exists then
      return jsonb_build_object(
        'ok', false,
        'code', 'DATASET_SOURCE_NOT_FOUND',
        'status', 404,
        'message', 'Source dataset version not found'
      );
    end if;

    -- Result isolation: a published Result Process is never a version source, because
    -- the derived row would be created as an ordinary owner-ready draft. The source row
    -- is locked first so its state cannot change between this admission check and the
    -- insert, and the established per-identity advisory lock above is retained; no broad
    -- table lock is taken. The check reads the source's own state, so it holds even when
    -- no publication receipt exists.
    if p_table = 'processes' then
      execute format(
        'select d.state_code from public.%I d where d.id = $1 and d.version = $2 for update of d',
        p_table
      )
        into v_source_state
        using p_id, v_source_version;

      if v_source_state = 120 then
        return jsonb_build_object(
          'ok', false,
          'code', 'RESULT_VERSION_DERIVATION_BLOCKED',
          'status', 403,
          'message', 'A published Result Process cannot be used as a version source',
          'details', jsonb_build_object(
            'state_code', v_source_state
          )
        );
      end if;
    end if;

    execute format(
      'select version::text
         from public.%I
        where id = $1
          and version::text ~ ''^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$''
        order by split_part(version::text, ''.'', 1)::integer desc,
                 split_part(version::text, ''.'', 2)::integer desc,
                 split_part(version::text, ''.'', 3)::integer desc
        limit 1',
      p_table
    )
      into v_highest_version
      using p_id;

    if v_highest_version is null then
      v_parts := array[0, 0, -1];
    else
      v_parts := array[
        split_part(v_highest_version, '.', 1)::integer,
        split_part(v_highest_version, '.', 2)::integer,
        split_part(v_highest_version, '.', 3)::integer
      ];
    end if;

    v_parts[3] := v_parts[3] + 1;

    if v_parts[3] > 999 then
      v_parts[3] := 0;
      v_parts[2] := v_parts[2] + 1;
    end if;

    if v_parts[2] > 99 then
      v_parts[2] := 0;
      v_parts[1] := v_parts[1] + 1;
    end if;

    v_next_version := lpad(v_parts[1]::text, 2, '0')
      || '.'
      || lpad(v_parts[2]::text, 2, '0')
      || '.'
      || lpad(v_parts[3]::text, 3, '0');
    v_next_uri := 'https://lcdn.tiangong.earth/datasetdetail/'
      || v_uri_slug
      || '.xhtml?uuid='
      || p_id::text
      || '&version='
      || v_next_version;

    v_payload := p_json_ordered;
    v_dataset := coalesce(v_payload->v_root_key, '{}'::jsonb);
    v_admin := coalesce(v_dataset->'administrativeInformation', '{}'::jsonb);
    v_pub := coalesce(v_admin->'publicationAndOwnership', '{}'::jsonb);
    v_pub := jsonb_set(v_pub, '{common:dataSetVersion}', to_jsonb(v_next_version), true);
    v_pub := jsonb_set(v_pub, '{common:permanentDataSetURI}', to_jsonb(v_next_uri), true);
    v_admin := jsonb_set(v_admin, '{publicationAndOwnership}', v_pub, true);
    v_dataset := jsonb_set(v_dataset, '{administrativeInformation}', v_admin, true);
    v_payload := jsonb_set(v_payload, array[v_root_key], v_dataset, true);

    if p_table = 'processes' then
      execute format(
        'insert into public.%I as t (id, json_ordered, model_id, model_version, rule_verification)
         values ($1, $2::json, $3, $4, $5)
         returning jsonb_build_object(
           ''id'', t.id,
           ''version'', t.version,
           ''state_code'', t.state_code,
           ''user_id'', t.user_id,
           ''team_id'', t.team_id,
           ''model_id'', t.model_id,
           ''model_version'', t.model_version,
           ''rule_verification'', t.rule_verification,
           ''json_ordered'', t.json_ordered::jsonb
         )',
        p_table
      )
        into v_created_row
        using p_id, v_payload, p_model_id, v_model_version, p_rule_verification;
    else
      execute format(
        'insert into public.%I as t (id, json_ordered, rule_verification)
         values ($1, $2::json, $3)
         returning jsonb_build_object(
           ''id'', t.id,
           ''version'', t.version,
           ''state_code'', t.state_code,
           ''user_id'', t.user_id,
           ''team_id'', t.team_id,
           ''model_id'', null,
           ''model_version'', null,
           ''rule_verification'', t.rule_verification,
           ''json_ordered'', t.json_ordered::jsonb
         )',
        p_table
      )
        into v_created_row
        using p_id, v_payload, p_rule_verification;
    end if;
  exception
    when lock_not_available then
      return jsonb_build_object(
        'ok', false,
        'code', 'DATASET_CREATE_VERSION_LOCK_TIMEOUT',
        'status', 503,
        'message', 'Dataset version creation is temporarily blocked by concurrent database work'
      );
    when query_canceled then
      return jsonb_build_object(
        'ok', false,
        'code', 'DATASET_CREATE_VERSION_TIMEOUT',
        'status', 503,
        'message', 'Dataset version creation exceeded the database timeout'
      );
    when unique_violation then
      return jsonb_build_object(
        'ok', false,
        'code', '23505',
        'status', 409,
        'message', 'Dataset with the same id and version already exists'
      );
    when not_null_violation then
      return jsonb_build_object(
        'ok', false,
        'code', '23502',
        'status', 400,
        'message', 'Dataset version creation requires a valid id, version, and jsonOrdered payload'
      );
    when check_violation then
      return jsonb_build_object(
        'ok', false,
        'code', sqlstate,
        'status', 400,
        'message', sqlerrm
      );
  end;

  insert into private.command_audit_log (
    command,
    actor_user_id,
    target_table,
    target_id,
    target_version,
    payload
  )
  values (
    'cmd_dataset_create_version',
    v_actor,
    p_table,
    p_id,
    nullif(v_created_row->>'version', ''),
    coalesce(p_audit, '{}'::jsonb)
  );

  return jsonb_build_object(
    'ok', true,
    'data', v_created_row
  );
end;
$_$;

alter function api.cmd_dataset_create_version(text, uuid, text, jsonb, uuid, boolean, jsonb, text) owner to postgres;
revoke all on function api.cmd_dataset_create_version(text, uuid, text, jsonb, uuid, boolean, jsonb, text) from public;
grant all on function api.cmd_dataset_create_version(text, uuid, text, jsonb, uuid, boolean, jsonb, text) to api_internal_executor;
grant all on function api.cmd_dataset_create_version(text, uuid, text, jsonb, uuid, boolean, jsonb, text) to authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
