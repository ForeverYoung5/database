begin;
set local lock_timeout='5s';
set local statement_timeout='2min';
-- Database #838: one canonical classification predicate for all dataset readers.
-- Source labels are deliberately excluded from matching. Both repeated ILCD
-- container levels support object and array forms; paths stay inside one system.
create or replace function private.dataset_catalog_filter_validate(p_filter jsonb)
returns void
language plpgsql immutable
set search_path = pg_catalog, pg_temp
as $$
declare selected jsonb; part jsonb;
begin
  if p_filter is null then return; end if;
  if jsonb_typeof(p_filter) <> 'object' then
    raise exception using errcode='22023', message='dataset filter must be an object';
  end if;
  if p_filter ? 'classification' then
    if jsonb_typeof(p_filter->'classification') <> 'array'
       or jsonb_array_length(p_filter->'classification') > 50 then
      raise exception using errcode='22023', message='classification must be an array of at most 50 selectors';
    end if;
    for selected in select value from jsonb_array_elements(p_filter->'classification') loop
      if jsonb_typeof(selected) <> 'object'
         or coalesce(selected->>'scope','') not in ('classification','elementary')
         or jsonb_typeof(selected->'code') <> 'string'
         or coalesce(btrim(selected->>'code'),'') = ''
         or length(selected->>'code') > 200 then
        raise exception using errcode='22023', message='invalid classification selector';
      end if;
      if selected ? 'system' and (jsonb_typeof(selected->'system') <> 'string'
         or coalesce(btrim(selected->>'system'),'') = '' or length(selected->>'system') > 200) then
        raise exception using errcode='22023', message='invalid classification system';
      end if;
      if selected ? 'path' then
        if jsonb_typeof(selected->'path') <> 'array'
           or jsonb_array_length(selected->'path') not between 1 and 20 then
          raise exception using errcode='22023', message='classification path must contain 1 to 20 codes';
        end if;
        for part in select value from jsonb_array_elements(selected->'path') loop
          if jsonb_typeof(part) <> 'string' or btrim(part #>> '{}') = '' or length(part #>> '{}') > 200 then
            raise exception using errcode='22023', message='invalid classification path code';
          end if;
        end loop;
        if btrim(selected->>'code') <> btrim(selected->'path'->>-1) then
          raise exception using errcode='22023', message='classification code must be the final path code';
        end if;
      end if;
    end loop;
  end if;
  if p_filter ? 'sourceEntityKinds' then
    if jsonb_typeof(p_filter->'sourceEntityKinds') <> 'array' or jsonb_array_length(p_filter->'sourceEntityKinds') not between 1 and 7
      or exists(select 1 from jsonb_array_elements(p_filter->'sourceEntityKinds') item
        where jsonb_typeof(item) <> 'string' or (item #>> '{}') not in ('process','flow','lifecyclemodel','contact','source','unitgroup','flowproperty')) then
      raise exception using errcode='22023',message='invalid source entity kinds';
    end if;
  end if;
  if p_filter ? 'datasetId' and (jsonb_typeof(p_filter->'datasetId') <> 'string'
     or coalesce(p_filter->>'datasetId','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception using errcode='22023', message='datasetId must be a UUID';
  end if;
  if p_filter ? 'flowReference' then
    if jsonb_typeof(p_filter->'flowReference') <> 'object'
       or coalesce(p_filter->'flowReference'->>'id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or (p_filter->'flowReference' ? 'version' and
           (jsonb_typeof(p_filter->'flowReference'->'version') <> 'string'
            or coalesce(p_filter->'flowReference'->>'version','') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'))
       or (p_filter->'flowReference' ? 'direction' and
           lower(coalesce(p_filter->'flowReference'->>'direction','')) not in ('input','output')) then
      raise exception using errcode='22023', message='invalid flow reference filter';
    end if;
  end if;
end;
$$;

create or replace function private.dataset_catalog_classification_matches(
  p_kind text, p_json jsonb, p_selectors jsonb
) returns boolean
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
  information jsonb; containers jsonb; container jsonb; nodes jsonb;
  selected jsonb; node jsonb; code_key text; selected_path jsonb;
  system_name text; actual_path text[]; expected_path text[]; actual_levels integer[];
begin
  if p_selectors is null or p_selectors = '[]'::jsonb then return true; end if;
  information := case p_kind
    when 'process' then p_json #> '{processDataSet,processInformation,dataSetInformation,classificationInformation}'
    when 'flow' then p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation}'
    when 'lifecyclemodel' then p_json #> '{lifeCycleModelDataSet,lifeCycleModelInformation,dataSetInformation,classificationInformation}'
    when 'contact' then p_json #> '{contactDataSet,contactInformation,dataSetInformation,classificationInformation}'
    when 'source' then p_json #> '{sourceDataSet,sourceInformation,dataSetInformation,classificationInformation}'
    when 'unitgroup' then p_json #> '{unitGroupDataSet,unitGroupInformation,dataSetInformation,classificationInformation}'
    when 'flowproperty' then p_json #> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,classificationInformation}'
    else null end;
  for selected in select value from jsonb_array_elements(p_selectors) loop
    if selected->>'scope' = 'elementary' then
      if p_kind <> 'flow' then continue; end if;
      containers := information->'common:elementaryFlowCategorization';
      code_key := '@catId';
    else
      containers := information->'common:classification';
      code_key := '@classId';
    end if;
    for container in select value from jsonb_array_elements(case jsonb_typeof(containers)
      when 'object' then jsonb_build_array(containers) when 'array' then containers else '[]'::jsonb end) loop
      system_name := nullif(btrim(container->>'@name'),'');
      if selected ? 'system' and system_name is distinct from btrim(selected->>'system') then continue; end if;
      nodes := container->(case when selected->>'scope'='elementary' then 'common:category' else 'common:class' end);
      nodes := case jsonb_typeof(nodes) when 'object' then jsonb_build_array(nodes) when 'array' then nodes else '[]'::jsonb end;
      if selected ? 'path' then
        select array_agg(btrim(value) order by ordinal) into expected_path
          from jsonb_array_elements_text(selected->'path') with ordinality as path(value,ordinal);
        -- A path is an ordered ancestor prefix from level zero in this very
        -- container. Duplicate or missing levels fail rather than cross-match.
        select array_agg(btrim(entry.item->>code_key) order by entry.level),array_agg(entry.level order by entry.level) into actual_path,actual_levels
        from (
          select item, case when item->>'@level' ~ '^[0-9]{1,2}$'
            then (item->>'@level')::integer else (ordinal-1)::integer end as level
          from jsonb_array_elements(nodes) with ordinality as classes(item,ordinal)
        ) entry where entry.level < cardinality(expected_path);
        if actual_path = expected_path and actual_levels = array(select generate_series(0,cardinality(expected_path)-1)) then return true; end if;
      elsif exists (select 1 from jsonb_array_elements(nodes) item
        where btrim(item->>code_key) = btrim(selected->>'code')) then return true;
      end if;
    end loop;
  end loop;
  return false;
end;
$$;

create or replace function private.dataset_catalog_filter_matches(p_kind text,p_json jsonb,p_filter jsonb)
returns boolean
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
  filter_json jsonb := coalesce(p_filter,'{}'::jsonb);
  type_filter text; flow_reference jsonb; exchanges jsonb;
begin
  p_kind := coalesce(p_kind, case when p_json ? 'processDataSet' then 'process' when p_json ? 'flowDataSet' then 'flow' when p_json ? 'lifeCycleModelDataSet' then 'lifecyclemodel' when p_json ? 'contactDataSet' then 'contact' when p_json ? 'sourceDataSet' then 'source' when p_json ? 'unitGroupDataSet' then 'unitgroup' when p_json ? 'flowPropertyDataSet' then 'flowproperty' else null end);
  perform private.dataset_catalog_filter_validate(filter_json);
  if not private.dataset_catalog_classification_matches(p_kind,p_json,filter_json->'classification') then return false; end if;
  filter_json := filter_json - 'classification' - 'datasetId' - 'sourceEntityKinds';
  flow_reference := filter_json->'flowReference';
  filter_json := filter_json - 'flowReference';
  if flow_reference is not null then
    if p_kind <> 'process' then return false; end if;
    exchanges := p_json #> '{processDataSet,exchanges,exchange}';
    if not exists (
      select 1 from jsonb_array_elements(case jsonb_typeof(exchanges)
        when 'object' then jsonb_build_array(exchanges) when 'array' then exchanges else '[]'::jsonb end) exchange
      where lower(exchange->'referenceToFlowDataSet'->>'@refObjectId') = lower(flow_reference->>'id')
        and (not flow_reference ? 'version' or exchange->'referenceToFlowDataSet'->>'@version'=flow_reference->>'version')
        and (not flow_reference ? 'direction' or lower(exchange->>'exchangeDirection')=lower(flow_reference->>'direction'))
    ) then return false; end if;
  end if;
  if p_kind = 'process' then
    type_filter := nullif(btrim(filter_json->>'typeOfDataSet'),'');
    filter_json := filter_json - 'typeOfDataSet';
    if type_filter is not null and type_filter <> 'all'
      and p_json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}' is distinct from type_filter then return false; end if;
  elsif p_kind='flow' then
    type_filter := nullif(btrim(filter_json->>'flowType'),'');
    filter_json := filter_json - 'flowType';
    if type_filter is not null and not coalesce(p_json #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' = any(string_to_array(type_filter,',')),false) then return false; end if;
    if coalesce(filter_json->>'asInput','false')::boolean and p_json @> '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"classificationInformation":{"common:elementaryFlowCategorization":{"common:category":[{"#text":"Emissions","@level":"0"}]}}}}}}'::jsonb then return false; end if;
    filter_json := filter_json - 'asInput';
  end if;
  return coalesce(p_json @> filter_json,false);
end;
$$;

-- Existing Open Data list/full-text/reference/Hybrid call this same predicate
-- before recall, latest selection, count and pagination. Preserve its identity.
create or replace function private.open_data_catalog_filter_matches(p_dataset_kind text,p_json jsonb,p_filter_condition jsonb)
returns boolean language sql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$ select private.dataset_catalog_filter_matches(p_dataset_kind,p_json,p_filter_condition) $$;

create or replace function api.query_dataset_catalog(
  p_dataset_kind text,
  p_data_source text default 'tg', p_filter_condition jsonb default '{}'::jsonb,
  p_state_code integer default null, p_team_id uuid default null,
  p_page_size integer default 50, p_page_current integer default 1,
  p_sort_by text default 'modified_at', p_sort_direction text default 'desc',
  p_owner_draft_only boolean default false, p_version_scope text default 'latest'
) returns table(id uuid,"json" jsonb,version character(9),modified_at timestamptz,created_at timestamptz,state_code integer,
  team_id uuid,model_id uuid,model_version character(9),total_count bigint)
language plpgsql stable security definer
set search_path = pg_catalog, api, private, public, extensions, pg_temp
set row_security='on'
set statement_timeout = '20s'
as $$
declare
  kind text := lower(btrim(p_dataset_kind)); source text := lower(btrim(p_data_source));
  actor uuid := private.dataset_search_effective_user_id('');
  team_allowed boolean := private.dataset_search_can_read_team_filter(p_team_id,actor);
  relation regclass; model_select text := 'null::uuid as model_id,null::character(9) as model_version';
  filter_json jsonb := coalesce(p_filter_condition,'{}'::jsonb); offset_rows bigint;
  selection text; sql_query text;
begin
  relation := case kind when 'process' then 'public.processes'::regclass when 'flow' then 'public.flows'::regclass
    when 'lifecyclemodel' then 'public.lifecyclemodels'::regclass when 'contact' then 'public.contacts'::regclass
    when 'source' then 'public.sources'::regclass when 'unitgroup' then 'public.unitgroups'::regclass
    when 'flowproperty' then 'public.flowproperties'::regclass else null end;
  if relation is null or source not in ('tg','co','my','te','ex','all_data') or source is null then
    raise exception using errcode='22023',message='unsupported dataset kind or data source';
  end if;
  if p_page_size is null or p_page_size not between 1 and 100 or p_page_current is null or p_page_current < 1 then
    raise exception using errcode='22023',message='invalid dataset pagination';
  end if;
  offset_rows := (p_page_current::bigint-1)*p_page_size;
  if offset_rows > 2147483647 then raise exception using errcode='22023',message='dataset page offset is too large'; end if;
  if p_version_scope is null or p_version_scope not in ('latest','all') then
    raise exception using errcode='22023',message='version scope must be latest or all';
  end if;
  if p_sort_by is null or p_sort_by not in ('id','version','created_at','modified_at')
    or p_sort_direction is null or p_sort_direction not in ('asc','desc') then
    raise exception using errcode='22023',message='invalid dataset sort';
  end if;
  perform private.dataset_catalog_filter_validate(filter_json);
  if kind not in ('flow','all') and exists(select 1 from jsonb_array_elements(coalesce(filter_json->'classification','[]'::jsonb)) selected where selected->>'scope'='elementary') then
    raise exception using errcode='22023',message='elementary classification requires Flow data';
  end if;
  if (source in ('my','te','ex','all_data') or p_owner_draft_only) and actor is null then return; end if;
  if source='te' and (p_team_id is null or not team_allowed) then return; end if;
  if kind='process' then model_select := 'd.model_id,d.model_version'; end if;
  selection := case p_version_scope when 'all' then 'select * from matching' else
    'select distinct on (id) * from matching order by id,version desc,modified_at desc' end;
  sql_query := format($query$
    with matching as (
      select d.id,d.json,d.version,d.modified_at,d.created_at,d.state_code,d.team_id,%2$s
      from %1$s d
      where (
        ($7 and (d.state_code=100 or (d.user_id=$2 and d.state_code=0)))
        or (not $7 and (
          ($1='tg' and d.state_code=100 and ($3 is null or d.team_id=$3))
          or ($1='co' and d.state_code=200 and ($3 is null or d.team_id=$3))
          or ($1='my' and d.user_id=$2 and ($4 is null or d.state_code=$4))
          or ($1='all_data' and (d.state_code=100 or d.user_id=$2) and ($4 is null or d.state_code=$4))
          or ($1='te' and $5 and d.team_id=$3 and ($4 is null or d.state_code=$4))
          or ($1='ex' and d.state_code=-1 and $2 is not null and ($3 is null or d.team_id=$3))
        )))
        and (not $6 ? 'datasetId' or d.id=($6->>'datasetId')::uuid)
        and private.dataset_catalog_filter_matches(%3$L,d.json,$6)
    ), selected as (%4$s), counted as (
      select selected.*,count(*) over()::bigint as total_count from selected
    ) select id,json,version,modified_at,created_at,state_code,team_id,model_id,model_version,total_count
      from counted order by %5$I %6$s nulls last,id,version desc limit $8 offset $9
  $query$,relation,model_select,kind,selection,p_sort_by,p_sort_direction);
  return query execute sql_query using source,actor,p_team_id,p_state_code,team_allowed,filter_json,p_owner_draft_only,p_page_size,offset_rows;
end;
$$;

create or replace function api.search_dataset_uuid_mentions_page(
  p_dataset_kind text, p_uuid uuid,
  p_data_source text default 'tg', p_filter_condition jsonb default '{}'::jsonb,
  p_state_code integer default null, p_team_id uuid default null,
  p_page_size integer default 50, p_page_current integer default 1,
  p_sort_by text default 'modified_at', p_sort_direction text default 'desc',
  p_owner_draft_only boolean default false, p_version_scope text default 'latest'
) returns table(rank bigint,source_entity_kind text,source_id uuid,source_version character(9),
  source_name text,source_modified_at timestamptz,source_team_id uuid,source_json jsonb,
  matched_by text,matched_entity_table text,total_count bigint)
language plpgsql stable security definer
set search_path = pg_catalog, api, private, public, extensions, pg_temp
set row_security='on'
set statement_timeout = '20s'
as $$
declare
  kind text := lower(btrim(p_dataset_kind)); source text := lower(btrim(p_data_source));
  actor uuid := private.dataset_search_effective_user_id('');
  team_allowed boolean := private.dataset_search_can_read_team_filter(p_team_id,actor);
  relation regclass; filter_json jsonb := coalesce(p_filter_condition,'{}'::jsonb); offset_rows bigint;
  selection text; sql_query text; source_sql text;
begin
  relation := case kind when 'process' then 'public.processes'::regclass when 'flow' then 'public.flows'::regclass
    when 'lifecyclemodel' then 'public.lifecyclemodels'::regclass when 'contact' then 'public.contacts'::regclass
    when 'source' then 'public.sources'::regclass when 'unitgroup' then 'public.unitgroups'::regclass
    when 'flowproperty' then 'public.flowproperties'::regclass else null end;
  if kind is null or (relation is null and kind <> 'all') or source not in ('tg','co','my','te','ex','all_data') or source is null or p_uuid is null then
    raise exception using errcode='22023',message='unsupported UUID mention query';
  end if;
  if p_page_size is null or p_page_size not between 1 and 100 or p_page_current is null or p_page_current<1 then
    raise exception using errcode='22023',message='invalid dataset pagination';
  end if;
  offset_rows := (p_page_current::bigint-1)*p_page_size;
  if offset_rows>2147483647 then raise exception using errcode='22023',message='dataset page offset is too large'; end if;
  if p_version_scope is null or p_version_scope not in ('latest','all') then
    raise exception using errcode='22023',message='version scope must be latest or all';
  end if;
  if p_sort_by is null or p_sort_by not in ('id','version','created_at','modified_at')
    or p_sort_direction is null or p_sort_direction not in ('asc','desc') then
    raise exception using errcode='22023',message='invalid dataset sort';
  end if;
  perform private.dataset_catalog_filter_validate(filter_json);
  if kind not in ('flow','all') and exists(select 1 from jsonb_array_elements(coalesce(filter_json->'classification','[]'::jsonb)) selected where selected->>'scope'='elementary') then
    raise exception using errcode='22023',message='elementary classification requires Flow data';
  end if;
  if (source in ('my','te','ex','all_data') or p_owner_draft_only) and actor is null then return; end if;
  if source='te' and (p_team_id is null or not team_allowed) then return; end if;
  selection := case p_version_scope when 'all' then 'select * from visible' else
    'select distinct on (source_kind,id) * from visible order by source_kind,id,version desc,modified_at desc' end;
  -- Enumerate a fixed allowlist, never caller-supplied relation text. Each branch
  -- projects only common fields so different table layouts remain compatible.
  if kind = 'all' then
    select string_agg(format('select %L::text as source_kind,id,json,version,modified_at,created_at,team_id,user_id,state_code from public.%I',entry.kind,entry.table_name),' union all ' order by entry.position)
    into source_sql from (values ('process','processes',1),('flow','flows',2),('lifecyclemodel','lifecyclemodels',3),
      ('source','sources',4),('contact','contacts',5),('unitgroup','unitgroups',6),('flowproperty','flowproperties',7)) entry(kind,table_name,position);
  else
    source_sql := format('select %L::text as source_kind,id,json,version,modified_at,created_at,team_id,user_id,state_code from %s',kind,relation);
  end if;
  sql_query := format($query$
    with visible as (
      select d.source_kind,d.id,d.json,d.version,d.modified_at,d.created_at,d.team_id from (%1$s) d
      where (
        ($7 and (d.state_code=100 or (d.user_id=$2 and d.state_code=0)))
        or (not $7 and (
          ($1='tg' and d.state_code=100 and ($3 is null or d.team_id=$3))
          or ($1='co' and d.state_code=200 and ($3 is null or d.team_id=$3))
          or ($1='my' and d.user_id=$2 and ($4 is null or d.state_code=$4))
          or ($1='all_data' and (d.state_code=100 or d.user_id=$2) and ($4 is null or d.state_code=$4))
          or ($1='te' and $5 and d.team_id=$3 and ($4 is null or d.state_code=$4))
          or ($1='ex' and d.state_code=-1 and $2 is not null and ($3 is null or d.team_id=$3))
        ))) and (not $6 ? 'datasetId' or d.id=($6->>'datasetId')::uuid)
        and (not $6 ? 'sourceEntityKinds' or $6->'sourceEntityKinds' ? d.source_kind)
    ), latest as (%2$s), matched as (
      select latest.* from latest where json::text ilike $8
        and private.dataset_catalog_filter_matches(source_kind,json,$6)
    ), counted as (
      select matched.*,count(*) over()::bigint as total_count,
        row_number() over(order by case source_kind when 'process' then 1 when 'flow' then 2 when 'lifecyclemodel' then 3 when 'source' then 4 when 'contact' then 5 when 'unitgroup' then 6 else 7 end,%4$I %5$s nulls last,id,version desc)::bigint as rank from matched
    ) select rank,source_kind,id,version,private.dataset_json_display_name(source_kind,json),
      modified_at,team_id,json,'json_uuid_scan'::text,
      case source_kind when 'process' then 'public.processes' when 'flow' then 'public.flows' when 'lifecyclemodel' then 'public.lifecyclemodels' when 'source' then 'public.sources' when 'contact' then 'public.contacts' when 'unitgroup' then 'public.unitgroups' else 'public.flowproperties' end,total_count
      from counted order by rank limit $9 offset $10
  $query$,source_sql,selection,kind,p_sort_by,p_sort_direction);
  return query execute sql_query using source,actor,p_team_id,p_state_code,team_allowed,filter_json,p_owner_draft_only,
    '%'||p_uuid::text||'%',p_page_size,offset_rows;
end;
$$;

alter function private.dataset_catalog_filter_validate(jsonb) owner to postgres;
alter function private.dataset_catalog_classification_matches(text,jsonb,jsonb) owner to postgres;
alter function private.dataset_catalog_filter_matches(text,jsonb,jsonb) owner to postgres;
revoke all on function private.dataset_catalog_filter_validate(jsonb),private.dataset_catalog_classification_matches(text,jsonb,jsonb),private.dataset_catalog_filter_matches(text,jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function private.dataset_catalog_filter_validate(jsonb),private.dataset_catalog_classification_matches(text,jsonb,jsonb),private.dataset_catalog_filter_matches(text,jsonb,jsonb) to api_internal_executor,next_public_search_executor;
alter function api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) owner to postgres;
alter function api.search_dataset_uuid_mentions_page(text,uuid,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) owner to postgres;
revoke all on function api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text),api.search_dataset_uuid_mentions_page(text,uuid,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) from public,anon,authenticated,service_role;
grant execute on function api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) to authenticated,api_internal_executor;
grant execute on function api.search_dataset_uuid_mentions_page(text,uuid,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) to anon,authenticated,api_internal_executor;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role)
values ('api.query_dataset_catalog(text, text, jsonb, integer, uuid, integer, integer, text, text, boolean, text)','NX-CORE-02',false,true,false),
 ('api.search_dataset_uuid_mentions_page(text, uuid, text, jsonb, integer, uuid, integer, integer, text, text, boolean, text)','NX-CORE-02',true,true,false);
notify pgrst,'reload schema';


-- Freeze exact deployed predecessor bodies before changing only their filter
-- expressions. Signature, owner, ACL, RLS/visibility, ranking, version rules,
-- candidate budgets and no-filter fast paths are preserved. Unexpected drift
-- fails atomically; no broad function scan or best-effort replacement occurs.
select extensions.vector_dims('[1]'::extensions.vector);
-- Borrow only transaction-local SET/CREATE authority from the closed function
-- owners, restoring the complete predecessor membership and schema ACL facts.
create temp table dataset838_owner_authority on commit drop as
select role_name,
  (select to_jsonb(m) from pg_catalog.pg_auth_members m where m.roleid=role_name::regrole
    and m.member='postgres'::regrole and m.grantor=current_user::regrole) as own_grant,
  (select coalesce(jsonb_agg(to_jsonb(m) order by m.grantor,m.oid),'[]'::jsonb)
    from pg_catalog.pg_auth_members m where m.roleid=role_name::regrole and m.member='postgres'::regrole) as memberships
from (values ('api_internal_executor'),('next_public_search_executor')) owners(role_name);
create temp table dataset838_schema_authority on commit drop as
select oid,nspowner,nspacl from pg_catalog.pg_namespace where oid in ('private'::regnamespace,'api'::regnamespace);
do $borrow$
begin
  if current_user<>'postgres' then raise exception using errcode='42501',message='dataset catalog upgrade requires postgres migration actor'; end if;
  grant api_internal_executor to postgres with inherit false,set true;
  grant next_public_search_executor to postgres with inherit false,set true;
end;
$borrow$;

grant create on schema private to api_internal_executor,next_public_search_executor;
grant create on schema api to api_internal_executor;
-- The generic raw catalog retains restrictive RLS, including state-120 and
-- OAuth core-read admission, under the established NOBYPASSRLS internal actor.
alter function api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) owner to api_internal_executor;
alter function api.search_dataset_uuid_mentions_page(text,uuid,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text) owner to api_internal_executor;
do $upgrade$
declare target record; patch jsonb; definition text; previous text; occurrences integer;
begin
  for target in select * from (values
('private.search_processes_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text,text[])','9160caff7622a3c8325ee4817e4f7663','[["p.json @> $2","private.dataset_catalog_filter_matches(NULL, p.json, $2)",1],["p.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, p.json, filter_condition_jsonb)",1],["where p2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND p2.state_code = 100) OR (normalized_data_source = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and p2.state_code = 200 and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and p2.user_id = effective_user_id and (state_code_filter is null or p2.state_code = state_code_filter))\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and p2.team_id = team_id_filter and (state_code_filter is null or p2.state_code = state_code_filter))\n            )\n          order by p2.version desc, p2.modified_at desc","where p2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND p2.state_code = 100) OR (normalized_data_source = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and p2.state_code = 200 and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and p2.user_id = effective_user_id and (state_code_filter is null or p2.state_code = state_code_filter))\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and p2.team_id = team_id_filter and (state_code_filter is null or p2.state_code = state_code_filter))\n            )\n          and (case when coalesce(filter_condition_jsonb->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,p2.json,jsonb_build_object(''classification'',filter_condition_jsonb->''classification'')) end)\n          order by p2.version desc, p2.modified_at desc",1],["where p2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND p2.state_code = 100) OR ($5 = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or p2.team_id = $7))\n            or ($5 = ''co'' and p2.state_code = 200 and ($7 is null or p2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and p2.user_id = $6 and ($8 is null or p2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and $9 and p2.team_id = $7 and ($8 is null or p2.state_code = $8))\n          )\n        order by p2.version desc, p2.modified_at desc","where p2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND p2.state_code = 100) OR ($5 = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or p2.team_id = $7))\n            or ($5 = ''co'' and p2.state_code = 200 and ($7 is null or p2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and p2.user_id = $6 and ($8 is null or p2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and $9 and p2.team_id = $7 and ($8 is null or p2.state_code = $8))\n          )\n        and (case when coalesce($2->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,p2.json,jsonb_build_object(''classification'',$2->''classification'')) end)\n          order by p2.version desc, p2.modified_at desc",1]]'::jsonb),
('private.search_lifecyclemodels_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])','fb897744b4382a49989662dea7c95fdc','[["l.json @> $2","private.dataset_catalog_filter_matches(NULL, l.json, $2)",1],["l.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, l.json, filter_condition_jsonb)",1],["where l2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND l2.state_code = 100) OR (normalized_data_source = ''ex'' AND l2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or l2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and l2.state_code = 200 and (team_id_filter is null or l2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and l2.user_id = effective_user_id and (state_code_filter is null or l2.state_code = state_code_filter))\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and l2.team_id = team_id_filter and (state_code_filter is null or l2.state_code = state_code_filter))\n            )\n          order by l2.version desc, l2.modified_at desc","where l2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND l2.state_code = 100) OR (normalized_data_source = ''ex'' AND l2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or l2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and l2.state_code = 200 and (team_id_filter is null or l2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and l2.user_id = effective_user_id and (state_code_filter is null or l2.state_code = state_code_filter))\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and l2.team_id = team_id_filter and (state_code_filter is null or l2.state_code = state_code_filter))\n            )\n          and (case when coalesce(filter_condition_jsonb->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,l2.json,jsonb_build_object(''classification'',filter_condition_jsonb->''classification'')) end)\n          order by l2.version desc, l2.modified_at desc",1],["where l2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND l2.state_code = 100) OR ($5 = ''ex'' AND l2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or l2.team_id = $7))\n            or ($5 = ''co'' and l2.state_code = 200 and ($7 is null or l2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and l2.user_id = $6 and ($8 is null or l2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and $9 and l2.team_id = $7 and ($8 is null or l2.state_code = $8))\n          )\n        order by l2.version desc, l2.modified_at desc","where l2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND l2.state_code = 100) OR ($5 = ''ex'' AND l2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or l2.team_id = $7))\n            or ($5 = ''co'' and l2.state_code = 200 and ($7 is null or l2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and l2.user_id = $6 and ($8 is null or l2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and $9 and l2.team_id = $7 and ($8 is null or l2.state_code = $8))\n          )\n        and (case when coalesce($2->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,l2.json,jsonb_build_object(''classification'',$2->''classification'')) end)\n          order by l2.version desc, l2.modified_at desc",1]]'::jsonb),
('private.semantic_process_version_candidates_v1(text,text,double precision,integer,text)','d986dbdefb5a755956384df6c423f041','[["p.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, p.json, filter_condition_jsonb)",5]]'::jsonb),
('private.lexical_version_candidates_v1(text,text,text[],jsonb,text)','518e4aa1dd3a2f1ea5264157a118f066','[["source.json @> $2","private.dataset_catalog_filter_matches(NULL, source.json, $2)",1]]'::jsonb),
('private.semantic_flow_version_candidates_v1(text,text,double precision,integer,text)','904341050c9b77f82c64d5863f44bcff','[["f.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, f.json, filter_condition_jsonb)",5]]'::jsonb),
('private.next_actor_semantic_version_candidates_v2(text,extensions.vector,jsonb,text,text[],boolean,text[],text[],text,integer,uuid)','b639af636488b5a13939c3f9cbf9c6e5','[["source.json @> $4","private.dataset_catalog_filter_matches(NULL, source.json, $4)",2]]'::jsonb),
('private.next_public_semantic_version_candidates_v2(text,extensions.vector,jsonb,text,text[],boolean,text[],text[],text,uuid)','0c8bf1c082070de0bb30aaf0cb038fe1','[["source.json @> $3","private.dataset_catalog_filter_matches(NULL, source.json, $3)",3]]'::jsonb),
('private.next_public_lexical_version_candidates_v2(text,text,text[],jsonb,text,text[],boolean,text[],text[],text,uuid)','01e470ecc1778d72450f7e66fd1569e4','[["source.json @> $3","private.dataset_catalog_filter_matches(NULL, source.json, $3)",2]]'::jsonb),
('private.next_actor_lexical_version_candidates_v2(text,text,text[],jsonb,text,text[],boolean,text[],text[],text,integer,uuid)','4988ef0352409409f3a18d90c1c6b5dc','[["source.json @> $4","private.dataset_catalog_filter_matches(NULL, source.json, $4)",2]]'::jsonb),
('api.hybrid_search_process_versions_v2(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid,text)','bced32483f906c536c774c67925dc9dc','[["source.json @> filter_condition","private.dataset_catalog_filter_matches(NULL, source.json, filter_condition)",1]]'::jsonb),
('api.hybrid_search_flow_versions_v2(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','1fd880d7c0ab3edb084d01465c4cab2d','[["source.json @> v_residual","private.dataset_catalog_filter_matches(NULL, source.json, v_residual)",1],["v_residual := v_filter - ''flowType'' - ''asInput'' - ''classification'';","-- Multi-system/path predicates run against each source before recall.\n  -- The flat code sidecar cannot represent a complete system/path selector.\n  v_classification_codes := ''{}''::text[];\n  v_elementary_codes := ''{}''::text[];\n  v_residual := v_filter - ''flowType'' - ''asInput'';\n  perform private.dataset_catalog_filter_validate(v_filter);",1]]'::jsonb),
('api._search_simple_dataset_latest(regclass,text,jsonb,bigint,bigint,text,text,uuid,integer)','5e855e41f5a15d3d875458e7efffaada','[["d.json @> $2","private.dataset_catalog_filter_matches(NULL, d.json, $2)",1],["d.json @> $8","private.dataset_catalog_filter_matches(NULL, d.json, $8)",1],["where d2.id = matched_ids.id\n            and (\n              ((($4 = ''tg'' AND d2.state_code = 100) OR ($4 = ''ex'' AND d2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($6 is null or d2.team_id = $6))\n              or ($4 = ''co'' and d2.state_code = 200 and ($6 is null or d2.team_id = $6))\n              or ($4 = ''my'' and $5 is not null and d2.user_id = $5 and ($7 is null or d2.state_code = $7))\n              or ($4 = ''te'' and $6 is not null and d2.team_id = $6 and ($7 is null or d2.state_code = $7))\n            )\n          order by d2.version desc, d2.modified_at desc","where d2.id = matched_ids.id\n            and (\n              ((($4 = ''tg'' AND d2.state_code = 100) OR ($4 = ''ex'' AND d2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($6 is null or d2.team_id = $6))\n              or ($4 = ''co'' and d2.state_code = 200 and ($6 is null or d2.team_id = $6))\n              or ($4 = ''my'' and $5 is not null and d2.user_id = $5 and ($7 is null or d2.state_code = $7))\n              or ($4 = ''te'' and $6 is not null and d2.team_id = $6 and ($7 is null or d2.state_code = $7))\n            )\n          and (case when coalesce($8->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,d2.json,jsonb_build_object(''classification'',$8->''classification'')) end)\n          order by d2.version desc, d2.modified_at desc",1],["where d2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND d2.state_code = 100) OR ($5 = ''ex'' AND d2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or d2.team_id = $7))\n            or ($5 = ''co'' and d2.state_code = 200 and ($7 is null or d2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and d2.user_id = $6 and ($8 is null or d2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and d2.team_id = $7 and ($8 is null or d2.state_code = $8))\n          )\n        order by d2.version desc, d2.modified_at desc","where d2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND d2.state_code = 100) OR ($5 = ''ex'' AND d2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or d2.team_id = $7))\n            or ($5 = ''co'' and d2.state_code = 200 and ($7 is null or d2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and d2.user_id = $6 and ($8 is null or d2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and d2.team_id = $7 and ($8 is null or d2.state_code = $8))\n          )\n        and (case when coalesce($2->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,d2.json,jsonb_build_object(''classification'',$2->''classification'')) end)\n          order by d2.version desc, d2.modified_at desc",1]]'::jsonb),
('private.hybrid_search_simple_dataset_v2(regclass,text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','5fb8ea2c4f75de7ef67873d2ee73c884','[["d.json @> $2","private.dataset_catalog_filter_matches(NULL, d.json, $2)",1],["    ''public.unitgroups''::regclass\n  ) then","    ''public.unitgroups''::regclass,\n    ''public.lifecyclemodels''::regclass\n  ) then",1],["where %3$s\n      ),\n      latest_rows as (","where %3$s and (case when coalesce($2->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,d.json,jsonb_build_object(''classification'',$2->''classification'')) end)\n      ),\n      latest_rows as (",1]]'::jsonb),
('private.search_flows_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])','1178e017ba1527535d6cf55fb748266b','[["f.json @> $2","private.dataset_catalog_filter_matches(NULL, f.json, $2)",1],["f.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, f.json, filter_condition_jsonb)",1],["classification_filter := filter_condition_jsonb->''classification'';","classification_filter := ''[]''::jsonb;",1],["filter_condition_jsonb := filter_condition_jsonb - ''classification'';","-- Canonical selector remains in the residual predicate before recall.\n  perform private.dataset_catalog_filter_validate(filter_condition_jsonb);",1],["where f2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND f2.state_code = 100) OR (normalized_data_source = ''ex'' AND f2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or f2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and f2.state_code = 200 and (team_id_filter is null or f2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and f2.user_id = effective_user_id and (state_code_filter is null or f2.state_code = state_code_filter))\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and f2.team_id = team_id_filter and (state_code_filter is null or f2.state_code = state_code_filter))\n            )\n          order by f2.version desc, f2.modified_at desc","where f2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND f2.state_code = 100) OR (normalized_data_source = ''ex'' AND f2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or f2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and f2.state_code = 200 and (team_id_filter is null or f2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and f2.user_id = effective_user_id and (state_code_filter is null or f2.state_code = state_code_filter))\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and f2.team_id = team_id_filter and (state_code_filter is null or f2.state_code = state_code_filter))\n            )\n          and (case when coalesce(filter_condition_jsonb->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,f2.json,jsonb_build_object(''classification'',filter_condition_jsonb->''classification'')) end)\n          order by f2.version desc, f2.modified_at desc",1],["where f2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND f2.state_code = 100) OR ($5 = ''ex'' AND f2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or f2.team_id = $7))\n            or ($5 = ''co'' and f2.state_code = 200 and ($7 is null or f2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and f2.user_id = $6 and ($8 is null or f2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and $9 and f2.team_id = $7 and ($8 is null or f2.state_code = $8))\n          )\n        order by f2.version desc, f2.modified_at desc","where f2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND f2.state_code = 100) OR ($5 = ''ex'' AND f2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or f2.team_id = $7))\n            or ($5 = ''co'' and f2.state_code = 200 and ($7 is null or f2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and f2.user_id = $6 and ($8 is null or f2.state_code = $8))\n            or ($5 = ''te'' and $7 is not null and $9 and f2.team_id = $7 and ($8 is null or f2.state_code = $8))\n          )\n        and (case when coalesce($2->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,f2.json,jsonb_build_object(''classification'',$2->''classification'')) end)\n          order by f2.version desc, f2.modified_at desc",1]]'::jsonb),
('private.search_processes_latest_v2_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean)','97908f970b39e420b0d2686c0cf8bac7','[["p.json @> $2","private.dataset_catalog_filter_matches(NULL, p.json, $2)",1],["p.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, p.json, filter_condition_jsonb)",1],["where p2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND p2.state_code = 100) OR (normalized_data_source = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and p2.state_code = 200 and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and p2.user_id = effective_user_id and (state_code_filter is null or p2.state_code = state_code_filter) and (not owner_draft_only or (p2.state_code = 0)) and p2.state_code is distinct from 120)\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and p2.team_id = team_id_filter and (state_code_filter is null or p2.state_code = state_code_filter) and p2.state_code is distinct from 120)\n            )\n          order by p2.version desc, p2.modified_at desc","where p2.id = matched_ids.id\n            and (\n              (((normalized_data_source = ''tg'' AND p2.state_code = 100) OR (normalized_data_source = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''co'' and p2.state_code = 200 and (team_id_filter is null or p2.team_id = team_id_filter))\n              or (normalized_data_source = ''my'' and effective_user_id is not null and p2.user_id = effective_user_id and (state_code_filter is null or p2.state_code = state_code_filter) and (not owner_draft_only or (p2.state_code = 0)) and p2.state_code is distinct from 120)\n              or (normalized_data_source = ''te'' and team_id_filter is not null and can_read_team_filter and p2.team_id = team_id_filter and (state_code_filter is null or p2.state_code = state_code_filter) and p2.state_code is distinct from 120)\n            )\n          and (case when coalesce(filter_condition_jsonb->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,p2.json,jsonb_build_object(''classification'',filter_condition_jsonb->''classification'')) end)\n          order by p2.version desc, p2.modified_at desc",1],["where p2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND p2.state_code = 100) OR ($5 = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or p2.team_id = $7))\n            or ($5 = ''co'' and p2.state_code = 200 and ($7 is null or p2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and p2.user_id = $6 and ($8 is null or p2.state_code = $8) and (not $12 or (p2.state_code = 0)) and p2.state_code is distinct from 120)\n            or ($5 = ''te'' and $7 is not null and $9 and p2.team_id = $7 and ($8 is null or p2.state_code = $8) and p2.state_code is distinct from 120)\n          )\n        order by p2.version desc, p2.modified_at desc","where p2.id = matched_ids.id\n          and (\n            ((($5 = ''tg'' AND p2.state_code = 100) OR ($5 = ''ex'' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or p2.team_id = $7))\n            or ($5 = ''co'' and p2.state_code = 200 and ($7 is null or p2.team_id = $7))\n            or ($5 = ''my'' and $6 is not null and p2.user_id = $6 and ($8 is null or p2.state_code = $8) and (not $12 or (p2.state_code = 0)) and p2.state_code is distinct from 120)\n            or ($5 = ''te'' and $7 is not null and $9 and p2.team_id = $7 and ($8 is null or p2.state_code = $8) and p2.state_code is distinct from 120)\n          )\n        and (case when coalesce($2->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,p2.json,jsonb_build_object(''classification'',$2->''classification'')) end)\n          order by p2.version desc, p2.modified_at desc",1]]'::jsonb),
('private.semantic_flow_candidates(text,text,double precision,integer,text)','bfc593efe863a8ccd8248a5ef62e7868','[["f.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, f.json, filter_condition_jsonb)",5]]'::jsonb),
('private.semantic_lifecyclemodel_candidates(text,text,double precision,integer,text)','d1f542903540afef5bad4200eedc3108','[["l.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, l.json, filter_condition_jsonb)",5]]'::jsonb),
('private.semantic_process_candidates(text,text,double precision,integer,text)','4f157895edab414ae028c137704f68a9','[["p.json @> filter_condition_jsonb","private.dataset_catalog_filter_matches(NULL, p.json, filter_condition_jsonb)",5]]'::jsonb),
('private.semantic_simple_dataset_candidates(regclass,text,text,double precision,integer,text,integer,uuid)','5f1eed4d5c7e631ce9e3e4910cfb2832','[["d.json @> $2","private.dataset_catalog_filter_matches(NULL, d.json, $2)",1],["    ''public.unitgroups''::regclass\n  ) then","    ''public.unitgroups''::regclass,\n    ''public.lifecyclemodels''::regclass\n  ) then",1]]'::jsonb),
('private.hybrid_search_flows_v2_impl(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','159ae180f336ca2ed4281f0b6d9b9096','[["      )\n    ),\n    latest_rows as (","      ) and (case when coalesce((coalesce(nullif(btrim(filter_condition),''''),''{}'')::jsonb)->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,f.json,jsonb_build_object(''classification'',(coalesce(nullif(btrim(filter_condition),''''),''{}'')::jsonb)->''classification'')) end)\n    ),\n    latest_rows as (",1]]'::jsonb),
('private.hybrid_search_lifecyclemodels_v2_impl(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','f1e2f13c769428d61df6a634ac635b64','[["      )\n    ),\n    latest_rows as (","      ) and (case when coalesce((coalesce(nullif(btrim(filter_condition),''''),''{}'')::jsonb)->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,l.json,jsonb_build_object(''classification'',(coalesce(nullif(btrim(filter_condition),''''),''{}'')::jsonb)->''classification'')) end)\n    ),\n    latest_rows as (",1]]'::jsonb),
('private.hybrid_search_processes_v2_impl(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','fb155e89031c3f8835a0e806fd9ab246','[["      )\n    ),\n    latest_rows as (","      ) and (case when coalesce((coalesce(nullif(btrim(filter_condition),''''),''{}'')::jsonb)->''classification'',''[]''::jsonb)=''[]''::jsonb then true else private.dataset_catalog_filter_matches(NULL,p.json,jsonb_build_object(''classification'',(coalesce(nullif(btrim(filter_condition),''''),''{}'')::jsonb)->''classification'')) end)\n    ),\n    latest_rows as (",1]]'::jsonb)
  ) as targets(identity,source_md5,patches) loop
    if (select md5(prosrc) from pg_proc where oid=target.identity::regprocedure) is distinct from target.source_md5 then
      raise exception using errcode='55000',message='dataset search predecessor drift: '||target.identity;
    end if;
    definition := pg_get_functiondef(target.identity::regprocedure);
    for patch in select value from jsonb_array_elements(target.patches) loop
      previous := patch->>0;
      occurrences := (length(definition)-length(replace(definition,previous,'')))/length(previous);
      if occurrences is distinct from (patch->>2)::integer then
        raise exception using errcode='55000',message='dataset search patch boundary drift: '||target.identity;
      end if;
      definition := replace(definition,previous,patch->>1);
    end loop;
    execute format('set local role %I',(select pg_get_userbyid(proowner) from pg_proc where oid=target.identity::regprocedure));
    execute definition;
    reset role;
  end loop;
end;
$upgrade$;
revoke create on schema private from api_internal_executor,next_public_search_executor;
revoke create on schema api from api_internal_executor;
do $restore$
declare owner_record record; memberships_after jsonb;
begin
  for owner_record in select * from dataset838_owner_authority loop
    if owner_record.own_grant is null then
      execute format('revoke %I from postgres',owner_record.role_name);
    else
      execute format('grant %I to postgres with admin %s,inherit %s,set %s',owner_record.role_name,
        owner_record.own_grant->>'admin_option',owner_record.own_grant->>'inherit_option',owner_record.own_grant->>'set_option');
    end if;
    select coalesce(jsonb_agg(to_jsonb(m) order by m.grantor,m.oid),'[]'::jsonb) into memberships_after
      from pg_catalog.pg_auth_members m where m.roleid=owner_record.role_name::regrole and m.member='postgres'::regrole;
    if memberships_after is distinct from owner_record.memberships then
      raise exception using errcode='55000',message='dataset catalog owner authority did not restore';
    end if;
  end loop;
  if exists(select 1 from dataset838_schema_authority before_snapshot join pg_catalog.pg_namespace after_snapshot using(oid)
    where before_snapshot.nspowner is distinct from after_snapshot.nspowner or before_snapshot.nspacl is distinct from after_snapshot.nspacl) then
    raise exception using errcode='55000',message='dataset catalog schema authority did not restore';
  end if;
end;
$restore$;


-- Private exact source lookup for display-only classification and page metadata.
-- It is never exposed by PostgREST and gains no external EXECUTE grant.
create or replace function private.dataset_catalog_source_json(p_kind text,p_id uuid,p_version text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare relation text; source_json jsonb;
begin
  relation := case p_kind when 'process' then 'processes' when 'flow' then 'flows' when 'lifecyclemodel' then 'lifecyclemodels'
    when 'contact' then 'contacts' when 'source' then 'sources' when 'unitgroup' then 'unitgroups' when 'flowproperty' then 'flowproperties' else null end;
  if relation is null then raise exception using errcode='22023',message='unsupported source kind'; end if;
  execute pg_catalog.format('select json from public.%I where id=$1 and version=$2::character(9)',relation)
    into source_json using p_id,p_version;
  return source_json;
end;
$$;

create or replace function private.dataset_catalog_display_metadata(p_kind text,p_json jsonb)
returns jsonb language sql immutable parallel safe set search_path='' as $$
  select pg_catalog.jsonb_build_object(
    'location',case p_kind
      when 'process' then p_json #>> '{processDataSet,processInformation,geography,locationOfOperationSupplyOrProduction,@location}'
      when 'flow' then p_json #>> '{flowDataSet,flowInformation,geography,locationOfSupply,@location}'
      when 'lifecyclemodel' then p_json #>> '{lifeCycleModelDataSet,lifeCycleModelInformation,geography,locationOfOperationSupplyOrProduction,@location}' else null end,
    'reference_year',case p_kind
      when 'process' then p_json #>> '{processDataSet,processInformation,time,common:referenceYear}'
      when 'flow' then p_json #>> '{flowDataSet,flowInformation,time,common:referenceYear}'
      when 'lifecyclemodel' then p_json #>> '{lifeCycleModelDataSet,lifeCycleModelInformation,time,common:referenceYear}' else null end,
    'type_of_data_set',case p_kind
      when 'process' then p_json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}'
      when 'flow' then p_json #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' else null end
  );
$$;

create or replace function private.dataset_display_list_filtered(
  p_kind text,p_visibility text,p_query text,p_page_size integer,p_page integer,p_candidates boolean,p_filter_condition jsonb
) returns jsonb language plpgsql stable security definer
set search_path='' set statement_timeout='20s' as $$
declare result_json jsonb; filter_json jsonb := coalesce(p_filter_condition,'{}'::jsonb); search_sql text := ''; filter_sql text := '';
begin
  if auth.uid() is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_candidates then perform private.dataset_display_require_manager(); end if;
  if p_kind is null or p_kind not in ('all','lifecyclemodel','process','flow','flowproperty','unitgroup','source','contact')
    or p_visibility is null or p_visibility not in ('all','visible','hidden')
    or p_query is null or pg_catalog.octet_length(p_query)>512
    or p_page_size is null or p_page_size not between 1 and 100
    or p_page is null or p_page not between 1 and 1000000 then
    raise exception using errcode='22023',message='invalid display list filters or pagination';
  end if;
  perform private.dataset_catalog_filter_validate(filter_json);
  if p_kind='all' and pg_catalog.jsonb_array_length(coalesce(filter_json->'classification','[]'::jsonb))>0 then
    raise exception using errcode='22023',message='select a dataset kind before classification';
  end if;
  if p_query<>'' then
    search_sql := ' and (strpos(lower(coalesce(c.name::text,'''')),lower($3))>0 or strpos(c.dataset_id::text,lower($3))>0)';
  end if;
  if filter_json<>'{}'::jsonb and filter_json<>'{"classification":[]}'::jsonb then
    filter_sql := ' and (not $7 ? ''datasetId'' or c.dataset_id=($7->>''datasetId'')::uuid) and private.dataset_catalog_filter_matches(c.dataset_kind,private.dataset_catalog_source_json(c.dataset_kind,c.dataset_id,c.dataset_version),$7)';
  end if;
  execute $query$
    with eligible as materialized (
      select c.dataset_kind,c.dataset_id,c.dataset_version,coalesce(s.is_visible,false) as is_visible
      from private.dataset_display_catalog c
      left join private.dataset_display_settings s using(dataset_kind,dataset_id,dataset_version)
      where ($1='all' or c.dataset_kind=$1) and ($6 or s.is_visible)
        and ($2='all' or ($2='visible' and s.is_visible) or ($2='hidden' and not coalesce(s.is_visible,false)))
    $query$||search_sql||filter_sql||$query$
    ), page as materialized (
      select * from eligible order by dataset_kind,dataset_id,dataset_version desc limit $4 offset ($5::bigint-1)*$4
    ), hydrated as (
      select page.*,case when octet_length(c.name::text)<=16384 then c.name else null end as name,
        private.dataset_catalog_display_metadata(page.dataset_kind,
          private.dataset_catalog_source_json(page.dataset_kind,page.dataset_id,page.dataset_version)) as metadata
      from page cross join lateral (
        select source.name from private.dataset_display_catalog source
        where source.dataset_kind=page.dataset_kind and source.dataset_id=page.dataset_id and source.dataset_version=page.dataset_version offset 0
      ) c
    ) select jsonb_build_object('data',coalesce((select jsonb_agg(
      (case when $6 then to_jsonb(hydrated)-'metadata' else to_jsonb(hydrated)-'metadata'-'is_visible' end)||hydrated.metadata
      order by dataset_kind,dataset_id,dataset_version desc) from hydrated),'[]'::jsonb),'total',(select count(*) from eligible))
  $query$ into result_json using p_kind,p_visibility,p_query,p_page_size,p_page,p_candidates,filter_json;
  return result_json;
end;
$$;

create or replace function api.list_dataset_display_candidates_filtered(
  p_dataset_kind text default 'all',p_visibility text default 'all',p_query text default '',
  p_page_size integer default 50,p_page integer default 1,p_filter_condition jsonb default '{}'::jsonb
) returns jsonb language sql stable security definer set search_path='' set statement_timeout='20s' as $$
 select private.dataset_display_list_filtered(p_dataset_kind,p_visibility,p_query,p_page_size,p_page,true,p_filter_condition);
$$;
create or replace function api.list_displayed_datasets_filtered(
  p_dataset_kind text default 'all',p_query text default '',p_page_size integer default 50,p_page integer default 1,p_filter_condition jsonb default '{}'::jsonb
) returns jsonb language sql stable security definer set search_path='' set statement_timeout='20s' as $$
 select private.dataset_display_list_filtered(p_dataset_kind,'visible',p_query,p_page_size,p_page,false,p_filter_condition);
$$;

alter function private.dataset_catalog_source_json(text,uuid,text) owner to postgres;
alter function private.dataset_catalog_display_metadata(text,jsonb) owner to postgres;
alter function private.dataset_display_list_filtered(text,text,text,integer,integer,boolean,jsonb) owner to postgres;
revoke all on function private.dataset_catalog_source_json(text,uuid,text),private.dataset_catalog_display_metadata(text,jsonb),private.dataset_display_list_filtered(text,text,text,integer,integer,boolean,jsonb) from public,anon,authenticated,service_role,api_internal_executor;
alter function api.list_dataset_display_candidates_filtered(text,text,text,integer,integer,jsonb) owner to postgres;
alter function api.list_displayed_datasets_filtered(text,text,integer,integer,jsonb) owner to postgres;
revoke all on function api.list_dataset_display_candidates_filtered(text,text,text,integer,integer,jsonb),api.list_displayed_datasets_filtered(text,text,integer,integer,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.list_dataset_display_candidates_filtered(text,text,text,integer,integer,jsonb),api.list_displayed_datasets_filtered(text,text,integer,integer,jsonb) to authenticated,api_internal_executor;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role)
values ('api.list_dataset_display_candidates_filtered(text, text, text, integer, integer, jsonb)','NX-CORE-02',false,true,false),
 ('api.list_displayed_datasets_filtered(text, text, integer, integer, jsonb)','NX-CORE-02',false,true,false);

-- Additive selected-team/state model Hybrid route; legacy wire is unchanged.
create or replace function api.hybrid_search_lifecyclemodels_filtered(
  query_text text,query_embedding text,filter_condition jsonb default '{}'::jsonb,
  match_threshold double precision default 0.5,match_count integer default 20,
  lexical_weight double precision default 0.5,semantic_weight double precision default 0.5,
  rrf_k integer default 10,data_source text default 'tg',page_size integer default 10,
  page_current integer default 1,query_terms text[] default null,
  state_code_filter integer default null,team_id_filter uuid default null
) returns table(id uuid,"json" jsonb,version character,modified_at timestamptz,team_id uuid,total_count bigint)
language plpgsql stable security definer set search_path='api','private','public','util','extensions','pg_temp'
set statement_timeout='60s' as $$
begin
  if page_size>100 or match_count>100 or page_size<1 or page_current<1
     or (greatest(coalesce(page_current::bigint,1),1)-1)>2147483647::bigint/greatest(coalesce(page_size::bigint,10),1) then
    raise exception using errcode='22023',message='invalid bounded model Hybrid pagination';
  end if;
  perform private.dataset_catalog_filter_validate(filter_condition);
  return query select * from private.hybrid_search_simple_dataset_v2('public.lifecyclemodels'::regclass,
    query_text,query_embedding,filter_condition::text,match_threshold,match_count,lexical_weight,semantic_weight,
    rrf_k,data_source,page_size,page_current,query_terms,state_code_filter,team_id_filter);
end;
$$;
alter function api.hybrid_search_lifecyclemodels_filtered(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to postgres;
revoke all on function api.hybrid_search_lifecyclemodels_filtered(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) from public,anon,authenticated,service_role;
grant execute on function api.hybrid_search_lifecyclemodels_filtered(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated,api_internal_executor;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role)
values ('api.hybrid_search_lifecyclemodels_filtered(text, text, jsonb, double precision, integer, double precision, double precision, integer, text, integer, integer, text[], integer, uuid)','NX-CORE-02',true,true,false);

notify pgrst,'reload schema';

commit;
