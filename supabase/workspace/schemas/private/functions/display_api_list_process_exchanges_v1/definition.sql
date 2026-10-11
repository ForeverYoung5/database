CREATE OR REPLACE FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text" DEFAULT 'all'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_process_json jsonb;
  v_process_state integer;
  v_functional_unit jsonb;
  v_cursor jsonb;
  v_cursor_internal integer;
  v_cursor_internal_text text;
  v_cursor_kind text;
  v_rows jsonb := '[]'::jsonb;
  v_group record;
  v_row jsonb;
  v_last_row jsonb;
  v_count integer := 0;
  v_next_cursor text;
begin
  if pg_catalog.octet_length(coalesce(p_exchange_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := lower(btrim(coalesce(p_exchange_kind, 'all')));
  if p_process_id is null
     or p_process_version is null
     or p_process_version !~ '^\d{2}\.\d{2}\.\d{3}$'
     or v_kind not in ('all', 'technosphere', 'elementary', 'waste')
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select row.json, row.state_code
  into v_process_json, v_process_state
  from public.processes as row
  where row.id = p_process_id
    and row.version::text = p_process_version
    and private.portal_display_request_visible_v1('process',row.id,row.version::text)
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'processDataSet') = 'object'
  limit 1;
  if v_process_json is null then
    return null;
  end if;
  v_functional_unit := private.display_process_functional_unit_v1(v_process_state, v_process_json);

  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'processId' <> p_process_id::text
       or v_cursor ->> 'processVersion' <> p_process_version
       or v_cursor ->> 'filterKind' <> v_kind
       or coalesce(v_cursor ->> 'internalId', '') !~ '^(0|[1-9][0-9]{0,5})$'
       or v_cursor ->> 'kind' not in ('technosphere', 'elementary', 'waste') then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_internal_text := v_cursor ->> 'internalId';
    v_cursor_internal := v_cursor_internal_text::integer;
    v_cursor_kind := v_cursor ->> 'kind';
  end if;

  -- Duplicate detection spans the complete raw array, including rows behind the
  -- cursor or with invalid support. Hydration starts only after this cheap pass.
  -- Support trims IDs; group whitespace aliases before sorting their row kinds
  -- so the original (numeric ID, normalized ID, kind) cursor order is retained.
  if nullif(v_functional_unit ->> 'amount', '') is not null
     and nullif(v_functional_unit ->> 'unit', '') is not null then
    <<page_groups>>
    for v_group in
      with raw_exchanges as materialized (
        select exchange.item,
          exchange.item ->> '@dataSetInternalID' as raw_id,
          btrim(exchange.item ->> '@dataSetInternalID') as internal_id,
          count(*) over (partition by exchange.item ->> '@dataSetInternalID') as identity_count
        from private.display_json_items_v1(v_process_json #> '{processDataSet,exchanges,exchange}') as exchange(item)
      ), candidates as materialized (
        select item, raw_id, internal_id,
          case when internal_id ~ '^(0|[1-9][0-9]{0,5})$'
            then internal_id::integer end as internal_number
        from raw_exchanges
        where identity_count = 1
      )
      select internal_number, internal_id, jsonb_agg(item order by raw_id) as items
      from candidates
      where internal_number is not null
        and (v_cursor is null or internal_number >= v_cursor_internal)
      group by internal_number, internal_id
      order by internal_number, internal_id
    loop
      -- Only a same-ID group is materialized. Never hydrate the entire Process
      -- before LIMIT. Unsupported/nonmatching rows must still be skipped until
      -- a real lookahead is found (a sparse filter can scan the remaining IDs).
      for v_row in
        with supported as materialized (
          select private.display_exchange_support_v1(v_process_state, v_process_json, item) -> 'row' as row_data
          from jsonb_array_elements(v_group.items) as exchange(item)
        )
        select row_data
        from supported
        where row_data is not null
          and (v_kind = 'all' or row_data ->> 'kind' = v_kind)
          and (v_cursor is null or
            (v_group.internal_number, row_data ->> 'internalId', row_data ->> 'kind') >
            (v_cursor_internal, v_cursor_internal_text, v_cursor_kind))
        order by row_data ->> 'kind'
      loop
        if v_count = p_limit then
          v_next_cursor := private.display_cursor_encode_v1(jsonb_build_object(
            'v', 1,
            'processId', p_process_id::text,
            'processVersion', p_process_version,
            'filterKind', v_kind,
            'internalId', v_last_row ->> 'internalId',
            'kind', v_last_row ->> 'kind'
          ));
          exit page_groups;
        end if;
        v_rows := v_rows || jsonb_build_array(v_row);
        v_last_row := v_row;
        v_count := v_count + 1;
      end loop;
    end loop page_groups;
  end if;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-exchange-page.v1',
    'process', jsonb_build_object('id', p_process_id::text, 'version', p_process_version),
    'processContext', jsonb_build_object(
      'functionalUnit', v_functional_unit,
      'capabilityPolicyVersion', 'portal-display-capability-policy.v2'
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) TO "portal_public_executor";
