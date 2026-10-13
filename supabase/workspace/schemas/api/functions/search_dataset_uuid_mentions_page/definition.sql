CREATE OR REPLACE FUNCTION "api"."search_dataset_uuid_mentions_page"("p_dataset_kind" "text", "p_uuid" "uuid", "p_data_source" "text" DEFAULT 'tg'::"text", "p_filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "p_state_code" integer DEFAULT NULL::integer, "p_team_id" "uuid" DEFAULT NULL::"uuid", "p_page_size" integer DEFAULT 50, "p_page_current" integer DEFAULT 1, "p_sort_by" "text" DEFAULT 'modified_at'::"text", "p_sort_direction" "text" DEFAULT 'desc'::"text", "p_owner_draft_only" boolean DEFAULT false, "p_version_scope" "text" DEFAULT 'latest'::"text") RETURNS TABLE("rank" bigint, "source_entity_kind" "text", "source_id" "uuid", "source_version" character, "source_name" "text", "source_modified_at" timestamp with time zone, "source_team_id" "uuid", "source_json" "jsonb", "matched_by" "text", "matched_entity_table" "text", "total_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'api', 'private', 'public', 'extensions', 'pg_temp'
    SET "row_security" TO 'on'
    SET "statement_timeout" TO '20s'
    AS $_$
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
        and private.dataset_catalog_filter_matches(source_kind,json,$6 - 'datasetId' - 'sourceEntityKinds')
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
$_$;

ALTER FUNCTION "api"."search_dataset_uuid_mentions_page"("p_dataset_kind" "text", "p_uuid" "uuid", "p_data_source" "text", "p_filter_condition" "jsonb", "p_state_code" integer, "p_team_id" "uuid", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text", "p_owner_draft_only" boolean, "p_version_scope" "text") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "api"."search_dataset_uuid_mentions_page"("p_dataset_kind" "text", "p_uuid" "uuid", "p_data_source" "text", "p_filter_condition" "jsonb", "p_state_code" integer, "p_team_id" "uuid", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text", "p_owner_draft_only" boolean, "p_version_scope" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."search_dataset_uuid_mentions_page"("p_dataset_kind" "text", "p_uuid" "uuid", "p_data_source" "text", "p_filter_condition" "jsonb", "p_state_code" integer, "p_team_id" "uuid", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text", "p_owner_draft_only" boolean, "p_version_scope" "text") TO "anon";

GRANT ALL ON FUNCTION "api"."search_dataset_uuid_mentions_page"("p_dataset_kind" "text", "p_uuid" "uuid", "p_data_source" "text", "p_filter_condition" "jsonb", "p_state_code" integer, "p_team_id" "uuid", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text", "p_owner_draft_only" boolean, "p_version_scope" "text") TO "authenticated";
