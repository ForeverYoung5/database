CREATE OR REPLACE FUNCTION "api"."cmd_open_data_process_publish_batch"("p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_input_count integer;
  v_requested_count integer;
  v_existing_count integer;
  v_inserted_count integer;
  v_valid_count integer;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  if not exists (
    select 1
    from private.roles r
    where r.user_id = v_actor
      and r.team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and r.role::text = 'data_product_manager'
  ) then
    raise exception using errcode = '42501', message = 'data_product_manager role required';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'p_items must be a JSON array';
  end if;

  v_input_count := jsonb_array_length(p_items);
  if v_input_count < 1 or v_input_count > 100 then
    raise exception using errcode = '22023', message = 'p_items must contain between 1 and 100 items';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) item(value)
    where jsonb_typeof(item.value) is distinct from 'object'
      or jsonb_typeof(item.value -> 'id') is distinct from 'string'
      or jsonb_typeof(item.value -> 'version') is distinct from 'string'
      or not ((item.value ->> 'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      or not ((item.value ->> 'version') ~ '^\d{2}\.\d{2}\.\d{3}$')
  ) then
    raise exception using errcode = '22023', message = 'each item must contain a valid id and version';
  end if;

  select count(*)
  into v_requested_count
  from (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested;

  -- Lock in a stable order so concurrent overlapping batches cannot invert locks.
  perform p.id
  from public.processes p
  join (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested
    on requested.process_id = p.id
   and requested.process_version = p.version
  order by p.id, p.version
  for update of p;

  select count(*)
  into v_valid_count
  from public.processes p
  join (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested
    on requested.process_id = p.id
   and requested.process_version = p.version
  where p.state_code = 100;

  if v_valid_count <> v_requested_count then
    raise exception using
      errcode = '22023',
      message = 'all requested Process versions must exist with state_code 100';
  end if;

  select count(*)
  into v_existing_count
  from private.open_data_process_publications publication
  join (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested
    using (process_id, process_version);

  insert into private.open_data_process_publications (
    process_id,
    process_version,
    published_by
  )
  select distinct
    (item.value ->> 'id')::uuid,
    (item.value ->> 'version')::character(9),
    v_actor
  from jsonb_array_elements(p_items) item(value)
  order by 1, 2
  on conflict (process_id, process_version) do nothing;

  get diagnostics v_inserted_count = row_count;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'inputCount', v_input_count,
      'requestedCount', v_requested_count,
      'publishedCount', v_inserted_count,
      'alreadyPublishedCount', v_existing_count
    )
  );
end;
$_$;

ALTER FUNCTION "api"."cmd_open_data_process_publish_batch"("p_items" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_open_data_process_publish_batch"("p_items" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_open_data_process_publish_batch"("p_items" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."cmd_open_data_process_publish_batch"("p_items" "jsonb") TO "authenticated";
