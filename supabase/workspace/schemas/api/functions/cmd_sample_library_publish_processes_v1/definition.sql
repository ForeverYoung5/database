CREATE OR REPLACE FUNCTION "api"."cmd_sample_library_publish_processes_v1"("p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_requested integer;
  v_matched integer;
  v_existing integer;
  v_inserted integer;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_items', 'status', 400,
      'message', 'items must be a JSON array');
  end if;

  v_requested := jsonb_array_length(p_items);
  if v_requested < 1 or v_requested > 500 then
    return jsonb_build_object('ok', false, 'code', 'invalid_item_count', 'status', 400,
      'message', 'items must contain between 1 and 500 Process versions');
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) as item(value)
    where jsonb_typeof(item.value) is distinct from 'object'
       or jsonb_typeof(item.value->'id') is distinct from 'string'
       or jsonb_typeof(item.value->'version') is distinct from 'string'
       or item.value->>'id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       or item.value->>'version' !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
       or exists (
         select 1 from jsonb_object_keys(item.value) as key(name)
         where key.name not in ('id', 'version')
       )
  ) then
    return jsonb_build_object('ok', false, 'code', 'invalid_item', 'status', 400,
      'message', 'Each item must contain only a valid id and version');
  end if;

  if (
    select count(*)
    from (
      select distinct item.value->>'id' as id, item.value->>'version' as version
      from jsonb_array_elements(p_items) as item(value)
    ) as distinct_items
  ) <> v_requested then
    return jsonb_build_object('ok', false, 'code', 'duplicate_item', 'status', 400,
      'message', 'Duplicate Process versions are not allowed');
  end if;

  -- Lock every requested source row before the eligibility check so state_code cannot drift
  -- between validation and receipt insertion.
  perform 1
  from public.processes as process
  join (
    select (item.value->>'id')::uuid as id,
      (item.value->>'version')::character(9) as version
    from jsonb_array_elements(p_items) as item(value)
  ) as requested using (id, version)
  order by process.id, process.version
  for update of process;

  select count(*) into v_matched
  from public.processes as process
  join (
    select (item.value->>'id')::uuid as id,
      (item.value->>'version')::character(9) as version
    from jsonb_array_elements(p_items) as item(value)
  ) as requested using (id, version)
  where process.state_code = 100;

  if v_matched <> v_requested then
    return jsonb_build_object('ok', false, 'code', 'process_not_publishable', 'status', 409,
      'message', 'Every selected Process version must exist with state_code 100');
  end if;

  insert into private.sample_library_process_publications (
    process_id, process_version, published_by
  )
  select process.id, process.version, v_actor
  from public.processes as process
  join (
    select (item.value->>'id')::uuid as id,
      (item.value->>'version')::character(9) as version
    from jsonb_array_elements(p_items) as item(value)
  ) as requested using (id, version)
  order by process.id, process.version
  on conflict (process_id, process_version) do nothing;

  get diagnostics v_inserted = row_count;
  -- Derive the replay count after ON CONFLICT so concurrent identical publications
  -- still return a complete, internally consistent receipt.
  v_existing := v_requested - v_inserted;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'requestedCount', v_requested,
      'publishedCount', v_inserted,
      'alreadyPublishedCount', v_existing
    )
  );
end;
$_$;

ALTER FUNCTION "api"."cmd_sample_library_publish_processes_v1"("p_items" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_sample_library_publish_processes_v1"("p_items" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_sample_library_publish_processes_v1"("p_items" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."cmd_sample_library_publish_processes_v1"("p_items" "jsonb") TO "authenticated";
