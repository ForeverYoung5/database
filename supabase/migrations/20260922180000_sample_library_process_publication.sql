-- Database #684 / workspace #1464: data-product-manager sample library.
--
-- The publication relation is version-bound and append-only. Publishing never changes the
-- source Process state; every catalog query remains fixed to state_code = 100.

begin;

create table private.sample_library_process_publications (
  process_id uuid not null,
  process_version character(9) not null,
  published_by uuid not null,
  published_at timestamptz not null default now(),
  constraint sample_library_process_publications_pkey
    primary key (process_id, process_version),
  constraint sample_library_process_publications_process_fkey
    foreign key (process_id, process_version)
    references public.processes (id, version)
    on update restrict on delete restrict
);

alter table private.sample_library_process_publications owner to postgres;
alter table private.sample_library_process_publications enable row level security;

create index sample_library_process_publications_published_at_idx
  on private.sample_library_process_publications (published_at desc, process_id, process_version);

revoke all on table private.sample_library_process_publications
  from public, anon, authenticated, service_role;
grant select on table private.sample_library_process_publications to api_internal_executor;

create or replace function private.sample_library_process_publications_immutable_v1()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  raise exception using
    errcode = '55000',
    message = 'SAMPLE_LIBRARY_PUBLICATION_IMMUTABLE',
    detail = 'A sample-library Process publication is append-only.';
end;
$fn$;

alter function private.sample_library_process_publications_immutable_v1() owner to postgres;
revoke all on function private.sample_library_process_publications_immutable_v1()
  from public, anon, authenticated, service_role;

create trigger sample_library_process_publications_immutable
  before update or delete on private.sample_library_process_publications
  for each row execute function private.sample_library_process_publications_immutable_v1();

create or replace function api.qry_sample_library_datasets_v1(
  p_dataset_type text,
  p_origin text default 'all',
  p_publication_status text default 'all',
  p_page_size integer default 20,
  p_page_current integer default 1
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_dataset_type text := lower(coalesce(p_dataset_type, ''));
  v_origin text := lower(coalesce(p_origin, 'all'));
  v_publication_status text := lower(coalesce(p_publication_status, 'all'));
  v_table_name text;
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_page_current integer := greatest(coalesce(p_page_current, 1), 1);
  v_result jsonb;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;

  v_table_name := case v_dataset_type
    when 'lifecyclemodels' then 'lifecyclemodels'
    when 'processes' then 'processes'
    when 'flows' then 'flows'
    when 'flowproperties' then 'flowproperties'
    when 'unitgroups' then 'unitgroups'
    when 'sources' then 'sources'
    when 'contacts' then 'contacts'
    else null
  end;

  if v_table_name is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_dataset_type', 'status', 400,
      'message', 'Unsupported sample-library dataset type');
  end if;
  if v_origin not in ('all', 'literature', 'enterprise') then
    return jsonb_build_object('ok', false, 'code', 'invalid_origin', 'status', 400,
      'message', 'origin must be all, literature, or enterprise');
  end if;
  if v_publication_status not in ('all', 'published', 'unpublished') then
    return jsonb_build_object('ok', false, 'code', 'invalid_publication_status', 'status', 400,
      'message', 'publication status must be all, published, or unpublished');
  end if;
  if v_dataset_type <> 'processes' and v_publication_status <> 'all' then
    return jsonb_build_object('ok', false, 'code', 'publication_status_not_supported',
      'status', 400, 'message', 'Publication status applies only to Processes');
  end if;

  execute format($sql$
    with latest as (
      select distinct on (source.id)
        source.id,
        source.version,
        source.user_id,
        coalesce(source.json, source.json_ordered::jsonb) as content,
        source.modified_at
      from public.%I as source
      where source.state_code = 100
      order by source.id, source.version desc, source.modified_at desc nulls last
    ), filtered as (
      select
        latest.id,
        latest.version,
        latest.content,
        latest.modified_at,
        case when latest.user_id is null then 'literature' else 'enterprise' end as origin,
        publication.published_at
      from latest
      left join private.sample_library_process_publications as publication
        on $3 = 'processes'
       and publication.process_id = latest.id
       and publication.process_version = latest.version
      where ($4 = 'all'
        or ($4 = 'literature' and latest.user_id is null)
        or ($4 = 'enterprise' and latest.user_id is not null))
        and ($3 <> 'processes'
          or $5 = 'all'
          or ($5 = 'published' and publication.process_id is not null)
          or ($5 = 'unpublished' and publication.process_id is null))
    ), page as (
      select *
      from filtered
      order by modified_at desc nulls last, id, version desc
      limit $1 offset $2
    )
    select jsonb_build_object(
      'ok', true,
      'data', jsonb_build_object(
        'datasetType', $3,
        'page', $6,
        'pageSize', $1,
        'total', (select count(*) from filtered),
        'items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', page.id,
            'version', page.version,
            'json', page.content,
            'modifiedAt', page.modified_at,
            'origin', page.origin,
            'published', case when $3 = 'processes'
              then page.published_at is not null else null end,
            'publishedAt', page.published_at
          ) order by page.modified_at desc nulls last, page.id, page.version desc)
          from page
        ), '[]'::jsonb)
      )
    )
  $sql$, v_table_name)
  into v_result
  using v_page_size, (v_page_current - 1) * v_page_size,
    v_dataset_type, v_origin, v_publication_status, v_page_current;

  return v_result;
end;
$fn$;

alter function api.qry_sample_library_datasets_v1(text, text, text, integer, integer)
  owner to postgres;
revoke all on function api.qry_sample_library_datasets_v1(text, text, text, integer, integer)
  from public, anon, authenticated, service_role;
grant all on function api.qry_sample_library_datasets_v1(text, text, text, integer, integer)
  to api_internal_executor, authenticated;

create or replace function api.cmd_sample_library_publish_processes_v1(p_items jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
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
$fn$;

alter function api.cmd_sample_library_publish_processes_v1(jsonb) owner to postgres;
revoke all on function api.cmd_sample_library_publish_processes_v1(jsonb)
  from public, anon, authenticated, service_role;
grant all on function api.cmd_sample_library_publish_processes_v1(jsonb)
  to api_internal_executor, authenticated;

insert into private.api_capability_grants (
  routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role
) values
  ('api.qry_sample_library_datasets_v1(text, text, text, integer, integer)',
    'NX-CORE-02', false, true, false),
  ('api.cmd_sample_library_publish_processes_v1(jsonb)',
    'CLI-RPC-01', false, true, false)
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;

notify pgrst, 'reload schema';

commit;
