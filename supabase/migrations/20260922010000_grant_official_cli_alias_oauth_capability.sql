begin;

-- The official CLI client is environment-specific runtime state, so identify it by
-- the exact least-privilege class deployed before CLI-ALIAS-02 rather than
-- hardcoding a Production client UUID. The reviewed protected Time-alias v2
-- lifecycle (Database #673 / Foundry #60) added the CLI-ALIAS-02 capability to its
-- four actor-facing routes and the service-only executor callback, but the deployed
-- official client still carries the prior five-capability class, so a fresh official
-- OAuth session is refused by the pre-request hook with SQLSTATE 42501 before any
-- protected route is reached. Preview/local environments without that client are
-- valid no-ops; ambiguity fails closed.
do $issue_677_official_cli_alias_capability$
declare
  v_expected_before constant text[] := array[
    'CLI-RPC-01',
    'DB-CORE-READ-01',
    'DB-CORE-WRITE-01',
    'EDGE-BUNDLE-01',
    'NX-CORE-02'
  ];
  v_expected_after constant text[] := array[
    'CLI-ALIAS-02',
    'CLI-RPC-01',
    'DB-CORE-READ-01',
    'DB-CORE-WRITE-01',
    'EDGE-BUNDLE-01',
    'NX-CORE-02'
  ];
  v_matching_client_ids text[];
  v_client_id text;
  v_actual_capabilities text[];
  v_result jsonb;
  v_audit_id_before bigint;
begin
  -- Serialize environment-client configuration before selecting by capability
  -- shape. The service facade must acquire a conflicting RowExclusiveLock on
  -- this registry before it can create, enable, disable, or replace a client,
  -- so no matching client can appear inside the selection/mutation window.
  lock table private.oauth_client_registry in share row exclusive mode;

  select coalesce(array_agg(client.client_id order by client.client_id), array[]::text[])
  into v_matching_client_ids
  from private.oauth_client_registry as client
  where client.client_kind = 'cli'
    and client.enabled
    and coalesce((
      select array_agg(grant_row.capability_id order by grant_row.capability_id)
        filter (where grant_row.allowed)
      from private.oauth_client_capability_grants as grant_row
      where grant_row.client_id = client.client_id
    ), array[]::text[]) = v_expected_before;

  if cardinality(v_matching_client_ids) = 0 then
    return;
  end if;

  if cardinality(v_matching_client_ids) <> 1 then
    raise exception
      'Issue #677 expected at most one matching enabled CLI client, found %',
      cardinality(v_matching_client_ids);
  end if;

  v_client_id := v_matching_client_ids[1];

  perform 1
  from private.oauth_client_registry as client
  where client.client_id = v_client_id
    and client.client_kind = 'cli'
    and client.enabled
  for update;

  select coalesce(
    array_agg(grant_row.capability_id order by grant_row.capability_id)
      filter (where grant_row.allowed),
    array[]::text[]
  )
  into v_actual_capabilities
  from private.oauth_client_capability_grants as grant_row
  where grant_row.client_id = v_client_id;

  if v_actual_capabilities is distinct from v_expected_before then
    raise exception
      'Issue #677 CLI capability state changed after selection';
  end if;

  -- The four actor-facing protected routes must stay authenticated-only, and the
  -- service-only executor callback must stay service-role-only with no
  -- anon/authenticated reach.  Adding CLI-ALIAS-02 to the official client must
  -- never widen the callback to actors.
  if (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity) = any (array[
      'api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_gate_v2_guarded(uuid,text,text)'::regprocedure,
      'api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_read_v2(uuid)'::regprocedure,
      'api.cmd_dataset_alias_execution_execute_v2(uuid,text)'::regprocedure
    ])
  ) <> 5 or (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity) = any (array[
      'api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_gate_v2_guarded(uuid,text,text)'::regprocedure,
      'api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_read_v2(uuid)'::regprocedure
    ])
      and manifest.capability_id = 'CLI-ALIAS-02'
      and manifest.allow_authenticated
      and not manifest.allow_anon
      and not manifest.allow_service_role
  ) <> 4 or (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity)
        = 'api.cmd_dataset_alias_execution_execute_v2(uuid,text)'::regprocedure
      and manifest.capability_id = 'CLI-ALIAS-02'
      and manifest.allow_service_role
      and not manifest.allow_anon
      and not manifest.allow_authenticated
  ) <> 1 then
    raise exception
      'Issue #677 CLI-ALIAS-02 route manifest is not exact';
  end if;

  select coalesce(max(audit.id), 0)
  into v_audit_id_before
  from private.oauth_client_registry_audit as audit
  where audit.client_id = v_client_id;

  select api.svc_oauth_client_configure(
    v_client_id,
    'cli',
    true,
    v_expected_after
  )
  into v_result;

  select coalesce(
    array_agg(grant_row.capability_id order by grant_row.capability_id)
      filter (where grant_row.allowed),
    array[]::text[]
  )
  into v_actual_capabilities
  from private.oauth_client_capability_grants as grant_row
  where grant_row.client_id = v_client_id;

  if v_actual_capabilities is distinct from v_expected_after
     or v_result #> '{data,capabilities}' is distinct from to_jsonb(v_expected_after) then
    raise exception
      'Issue #677 CLI capability repair produced an unexpected after-state';
  end if;

  if (
    select count(*)
    from private.oauth_client_registry_audit as audit
    where audit.client_id = v_client_id
      and audit.id > v_audit_id_before
      and audit.action = 'replace'
      and audit.before_state -> 'capabilities' = to_jsonb(v_expected_before)
      and audit.after_state -> 'capabilities' = to_jsonb(v_expected_after)
  ) <> 1 then
    raise exception
      'Issue #677 CLI capability repair did not record one exact audit event';
  end if;
end
$issue_677_official_cli_alias_capability$;

commit;
