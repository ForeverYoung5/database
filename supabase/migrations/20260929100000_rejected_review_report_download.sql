-- Database #754: authorize a rejected Process submitter to download only the
-- current files of the exact review-report Source referenced by a terminal
-- rejected comment. Source metadata visibility remains governed by its RLS.

create or replace function private.review_report_reference_matches_v1(
  p_payload jsonb,
  p_source_id uuid,
  p_source_version text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with recursive nodes(node, parent_key) as (
    select coalesce(p_payload, 'null'::jsonb), null::text
    union all
    select child.node, coalesce(child.key, nodes.parent_key)
    from nodes
    cross join lateral (
      select object_item.key, object_item.value as node
      from pg_catalog.jsonb_each(
        case when pg_catalog.jsonb_typeof(nodes.node) = 'object'
          then nodes.node else '{}'::jsonb end
      ) as object_item
      union all
      select null::text, array_item.value
      from pg_catalog.jsonb_array_elements(
        case when pg_catalog.jsonb_typeof(nodes.node) = 'array'
          then nodes.node else '[]'::jsonb end
      ) as array_item
    ) as child
  )
  select exists (
    select 1
    from nodes
    where nodes.parent_key = 'common:referenceToCompleteReviewReport'
      and pg_catalog.jsonb_typeof(nodes.node) = 'object'
      and nodes.node->>'@refObjectId' = p_source_id::text
      and nodes.node->>'@version' = p_source_version
  );
$$;

alter function private.review_report_reference_matches_v1(jsonb, uuid, text) owner to postgres;
revoke all on function private.review_report_reference_matches_v1(jsonb, uuid, text)
  from public, anon, authenticated, service_role;

create or replace function api.qry_review_report_download_descriptor_v1(
  p_process_id uuid,
  p_process_version text,
  p_source_id uuid,
  p_source_version text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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
$$;

alter function api.qry_review_report_download_descriptor_v1(uuid, text, uuid, text)
  owner to postgres;
revoke all on function api.qry_review_report_download_descriptor_v1(uuid, text, uuid, text)
  from public, anon, service_role;
grant execute on function api.qry_review_report_download_descriptor_v1(uuid, text, uuid, text)
  to authenticated, api_internal_executor;

comment on function api.qry_review_report_download_descriptor_v1(uuid, text, uuid, text) is
  'Returns current external_docs attachment descriptors only when auth.uid() owns a terminal rejected Process review (including fail-closed legacy rows) whose terminal comment references the exact report Source id/version. Does not grant Source detail visibility.';

insert into private.api_capability_grants (
  routine_identity,
  capability_id,
  allow_anon,
  allow_authenticated,
  allow_service_role
)
values (
  'api.qry_review_report_download_descriptor_v1(uuid, text, uuid, text)',
  'NX-REV-01',
  false,
  true,
  false
)
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;
