CREATE OR REPLACE FUNCTION "api"."qry_review_report_download_descriptor_v1"("p_process_id" "uuid", "p_process_version" "text", "p_source_id" "uuid", "p_source_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_source_json jsonb;
  v_files jsonb;
  v_file jsonb;
  v_uri text;
  v_object_path text;
  v_filename text;
  v_descriptors jsonb := '[]'::jsonb;
begin
  if v_actor is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_process_id is null
    or p_source_id is null
    or p_process_version !~ '^\d{2}\.\d{2}\.\d{3}$'
    or p_source_version !~ '^\d{2}\.\d{2}\.\d{3}$'
  then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'REVIEW_REPORT_DOWNLOAD_NOT_ALLOWED',
      'status', 403,
      'message', 'Review report download is not allowed'
    );
  end if;

  if not exists (
    select 1
    from private.reviews as review_row
    join private.comments as comment_row on comment_row.review_id = review_row.id
    where review_row.data_id = p_process_id
      and review_row.data_version = p_process_version::character(9)
      and review_row.state_code = -1
      and (
        (
          review_row.review_kind = 'root'
          and review_row.target_table = 'processes'
          and review_row.target_owner_id = v_actor
        )
        or (
          review_row.review_kind is null
          and review_row.json->'data'->>'table' = 'processes'
          and review_row.json->'data'->>'id' = p_process_id::text
          and review_row.json->'data'->>'version' = p_process_version
          and exists (
            select 1
            from public.processes as process_row
            where process_row.id = p_process_id
              and process_row.version = p_process_version::character(9)
              and process_row.user_id = v_actor
          )
        )
      )
      and comment_row.state_code = -1
      and private.review_report_reference_matches_v1(
        comment_row.json::jsonb,
        p_source_id,
        p_source_version
      )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'REVIEW_REPORT_DOWNLOAD_NOT_ALLOWED',
      'status', 403,
      'message', 'Review report download is not allowed'
    );
  end if;

  select coalesce(source_row.json, source_row.json_ordered::jsonb)
  into v_source_json
  from public.sources as source_row
  where source_row.id = p_source_id
    and source_row.version = p_source_version::character(9);

  if v_source_json is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'REVIEW_REPORT_DOWNLOAD_NOT_ALLOWED',
      'status', 403,
      'message', 'Review report download is not allowed'
    );
  end if;

  v_files := v_source_json #> array[
    'sourceDataSet',
    'sourceInformation',
    'dataSetInformation',
    'referenceToDigitalFile'
  ];

  if v_files is null or v_files = 'null'::jsonb then
    v_files := '[]'::jsonb;
  elsif pg_catalog.jsonb_typeof(v_files) = 'object' then
    v_files := pg_catalog.jsonb_build_array(v_files);
  elsif pg_catalog.jsonb_typeof(v_files) <> 'array' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'REVIEW_REPORT_ATTACHMENT_INVALID',
      'status', 409,
      'message', 'Review report attachment metadata is invalid'
    );
  end if;

  if pg_catalog.jsonb_array_length(v_files) > 20 then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'REVIEW_REPORT_ATTACHMENT_INVALID',
      'status', 409,
      'message', 'Review report attachment metadata is invalid'
    );
  end if;

  for v_file in
    select file_item.value
    from pg_catalog.jsonb_array_elements(v_files) with ordinality as file_item(value, ordinality)
    order by file_item.ordinality
  loop
    if pg_catalog.jsonb_typeof(v_file) <> 'object' then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'code', 'REVIEW_REPORT_ATTACHMENT_INVALID',
        'status', 409,
        'message', 'Review report attachment metadata is invalid'
      );
    end if;

    v_uri := v_file->>'@uri';
    if v_uri is null or v_uri !~ '^\.\./external_docs/[^/].*$' then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'code', 'REVIEW_REPORT_ATTACHMENT_INVALID',
        'status', 409,
        'message', 'Review report attachment metadata is invalid'
      );
    end if;

    v_object_path := pg_catalog.substr(v_uri, pg_catalog.length('../external_docs/') + 1);
    if v_object_path = ''
      or v_object_path ~ '[\\[:cntrl:]]'
      or v_object_path ~ '(^|/)(\.{1,2})(/|$)'
      or v_object_path like '/%'
      or v_object_path like '%/'
    then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'code', 'REVIEW_REPORT_ATTACHMENT_INVALID',
        'status', 409,
        'message', 'Review report attachment metadata is invalid'
      );
    end if;

    v_filename := pg_catalog.regexp_replace(v_object_path, '^.*/', '');
    if v_filename = '' then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'code', 'REVIEW_REPORT_ATTACHMENT_INVALID',
        'status', 409,
        'message', 'Review report attachment metadata is invalid'
      );
    end if;

    v_descriptors := v_descriptors || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'bucket', 'external_docs',
        'objectPath', v_object_path,
        'filename', v_filename
      )
    );
  end loop;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'data', pg_catalog.jsonb_build_object('attachments', v_descriptors)
  );
end;
$_$;

ALTER FUNCTION "api"."qry_review_report_download_descriptor_v1"("p_process_id" "uuid", "p_process_version" "text", "p_source_id" "uuid", "p_source_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_review_report_download_descriptor_v1"("p_process_id" "uuid", "p_process_version" "text", "p_source_id" "uuid", "p_source_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_review_report_download_descriptor_v1"("p_process_id" "uuid", "p_process_version" "text", "p_source_id" "uuid", "p_source_version" "text") TO "authenticated";

GRANT ALL ON FUNCTION "api"."qry_review_report_download_descriptor_v1"("p_process_id" "uuid", "p_process_version" "text", "p_source_id" "uuid", "p_source_version" "text") TO "api_internal_executor";
