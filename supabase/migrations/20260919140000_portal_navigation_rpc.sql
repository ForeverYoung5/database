-- Database #656: bounded, version-aware hierarchy aggregation.
-- No per-node reads of the result universe; query candidates and filters are
-- shared with V3, and empty browse reads only the narrow public projection.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
grant portal_public_executor,api_internal_executor to postgres;
grant create on schema private,api to portal_public_executor;
grant select(contract_version,asset_sha256) on private.portal_navigation_contract_v1 to portal_public_executor;
create policy portal_navigation_contract_reader_v1 on private.portal_navigation_contract_v1
  for select to portal_public_executor using (contract_version=1);
-- Exposure is the cutover: require full public-version coverage after the four
-- backfills. Normal projection writers already maintain all subsequent changes.
do $coverage$
begin
  if exists(select 1 from private.portal_catalog_search_current_v2 p
    where not exists(select 1 from private.portal_navigation_versions_v1 n
      where (n.dataset_kind,n.id,n.version)=(p.dataset_kind,p.id,p.version))) then
    raise exception 'Portal navigation backfill is incomplete' using errcode='55000';
  end if;
end;
$coverage$;

create function private.portal_navigation_version_matches_v3(
  p_kind text,
  p_filters jsonb,
  p_id uuid,
  p_version text
)
returns boolean
language sql
stable
parallel safe
as $function$
  select
    (
      not (p_filters ? 'classificationNodeId')
      or exists (
        select 1
        from private.portal_navigation_membership_v1 as member
        where member.dataset_kind = p_kind
          and member.id = p_id
          and member.version = p_version
          and member.dimension = 'classification'
          and (
            case coalesce(p_filters ->> 'classificationScope', 'subtree')
              when 'direct' then
                member.node_id = p_filters ->> 'classificationNodeId'
                and member.direct
              else member.node_id = p_filters ->> 'classificationNodeId'
            end
          )
      )
    )
    and (
      not (p_filters ? 'geographyNodeId')
      or exists (
        select 1
        from private.portal_navigation_membership_v1 as member
        where member.dataset_kind = p_kind
          and member.id = p_id
          and member.version = p_version
          and member.dimension = 'geography'
          and (
            case coalesce(p_filters ->> 'geographyScope', 'subtree')
              when 'direct' then
                member.node_id = p_filters ->> 'geographyNodeId'
                and member.direct
              else member.node_id = p_filters ->> 'geographyNodeId'
            end
          )
      )
    )
$function$;

create function private.portal_validate_search_v3(
  p_kind text,
  p_query text,
  p_filters jsonb,
  p_sort text,
  p_limit integer
)
returns void
language plpgsql
stable
parallel safe
set search_path = ''
as $function$
declare
  v_base jsonb;
  v_key text;
  v_node_pattern constant text := '^[a-z][a-z0-9-]*:[!-~]{1,96}$';
begin
  perform private.assert_portal_navigation_projection_v1();
  if p_kind is null or p_kind not in ('process','flow','all') or p_filters is null or pg_catalog.jsonb_typeof(p_filters) <> 'object' or octet_length(p_filters::text)>4096 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  for v_key in select pg_catalog.jsonb_object_keys(p_filters)
  loop
    if v_key not in (
      'accessLevel', 'geography', 'classification', 'referenceYearFrom',
      'referenceYearTo', 'source', 'processSubtype',
      'classificationNodeId', 'classificationScope',
      'geographyNodeId', 'geographyScope'
    ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;

  for v_key in select unnest(array['classificationNodeId', 'geographyNodeId'])
  loop
    if p_filters ? v_key then
      if pg_catalog.jsonb_typeof(p_filters -> v_key) <> 'string'
         or (p_filters ->> v_key) !~ v_node_pattern then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
      -- The node must exist in the vocabulary and belong to the right axis.
      if not exists (
        select 1
        from private.portal_navigation_node_v1 as node
        where node.node_id = p_filters ->> v_key
          and node.dimension = case v_key
            when 'classificationNodeId' then 'classification'
            else 'geography'
          end
      ) then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
    end if;
  end loop;

  for v_key in select unnest(array['classificationScope', 'geographyScope'])
  loop
    if p_filters ? v_key and (
      pg_catalog.jsonb_typeof(p_filters -> v_key) <> 'string'
      or p_filters ->> v_key not in ('subtree', 'direct')
    ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;

  -- A scope without its node is invalid, and a classification node that the
  -- dataset kind can never carry is refused rather than silently empty.
  if p_filters ? 'classificationScope' and not (p_filters ? 'classificationNodeId') then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_filters ? 'geographyScope' and not (p_filters ? 'geographyNodeId') then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  select pg_catalog.jsonb_object_agg(filter.key, filter.value)
  into v_base
  from pg_catalog.jsonb_each(p_filters) as filter(key, value)
  where filter.key in (
    'accessLevel', 'geography', 'classification', 'referenceYearFrom',
    'referenceYearTo', 'source', 'processSubtype'
  );

  perform private.portal_validate_search_v1(
    p_kind, p_query, coalesce(v_base, '{}'::jsonb), p_sort, p_limit
  );
end;
$function$;

create function private.portal_navigation_matched_versions_v1(p_kind text,p_query text,p_filters jsonb)
returns table(dataset_kind text,id uuid,version text)
language plpgsql stable security definer parallel restricted
set search_path='' set row_security='on' set plan_cache_mode='force_custom_plan'
as $function$
declare
  v_exact uuid;
  v_pattern text;
begin
  if p_query='' then
    -- Empty/query-free navigation never detoasts public cards or raw source JSON.
    return query select v.dataset_kind,v.id,v.version
    from private.portal_navigation_versions_v1 v
    where (p_kind='all' or v.dataset_kind=p_kind) and
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and private.portal_navigation_version_matches_v3(v.dataset_kind,p_filters,v.id,v.version)
;
  else
    if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_exact:=p_query::uuid; end if;
    v_pattern := '%' || replace(replace(replace(p_query,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_') || '%';
    -- Reuse the exact UUID/CAS/literal/one-character candidate contract of V2.
    return query select v.dataset_kind,v.id,v.version
    from private.catalog_portal_facet_candidate_rows_v2(p_kind,p_query,v_exact,v_pattern) c
    join private.portal_navigation_versions_v1 v
      on (v.dataset_kind,v.id,v.version)=(c.dataset_kind,c.id,c.version)
    where
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and private.portal_navigation_version_matches_v3(v.dataset_kind,p_filters,v.id,v.version)
;
  end if;
end;
$function$;

create function private.portal_navigation_impl_v1(
  p_kind text,p_query text,p_filters jsonb,p_dimension text,p_parent_node_id text,
  p_cursor_node_id text,p_limit integer,p_fingerprint text
) returns jsonb language plpgsql stable security definer parallel restricted
set search_path='' set row_security='on' set plan_cache_mode='force_custom_plan'
set statement_timeout='8s' set work_mem='32MB'
as $function$
declare
  v_parent jsonb;
  v_ancestors jsonb:='[]';
  v_nodes jsonb;
  v_totals jsonb;
  v_next text;
  v_result jsonb;
  v_after_code text;
  v_trimmed boolean:=false;
begin
  perform private.assert_portal_navigation_contract_v1();
  if p_parent_node_id is not null and not exists (
    select 1 from private.portal_navigation_node_v1 n
    where n.node_id=p_parent_node_id and n.dimension=p_dimension
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped')
        or exists(select 1 from private.portal_navigation_membership_v1 m where m.node_id=n.node_id))
  ) then raise exception using errcode='22023',message='invalid portal request'; end if;
  if p_cursor_node_id is not null then
    select n.code into v_after_code from private.portal_navigation_node_v1 n
    where n.node_id=p_cursor_node_id and n.dimension=p_dimension
      and n.parent_node_id is not distinct from p_parent_node_id;
    if not found then raise exception using errcode='22023',message='invalid portal request'; end if;
  end if;

  with matched as materialized (
    select * from private.portal_navigation_matched_versions_v1('all',p_query,p_filters)
  ), children as materialized (
    select n.* from private.portal_navigation_node_v1 n
    where n.dimension=p_dimension and n.parent_node_id is not distinct from p_parent_node_id
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped') or exists (
        select 1 from private.portal_navigation_membership_v1 m join matched v using(dataset_kind,id,version)
        where m.node_id=n.node_id and (p_kind='all' or m.dataset_kind=p_kind)))
      and (p_dimension<>'classification' or p_kind='all' or n.taxonomy not in ('isic','cpc','elementary')
        or (p_kind='process' and n.taxonomy='isic') or (p_kind='flow' and n.taxonomy in ('cpc','elementary')))
      and (p_cursor_node_id is null or (n.code collate "C",n.node_id collate "C")>(v_after_code collate "C",p_cursor_node_id collate "C"))
    order by n.code collate "C",n.node_id collate "C" limit p_limit+1
  ), targets as materialized (
    select * from children
    union all
    select n.* from private.portal_navigation_node_v1 n where n.node_id=p_parent_node_id
  ), counted as materialized (
    select m.node_id,count(*) as count,count(*) filter(where m.direct) as direct_count
    from private.portal_navigation_membership_v1 m
    join matched v on (v.dataset_kind,v.id,v.version)=(m.dataset_kind,m.id,m.version)
    where m.dimension=p_dimension and (p_kind='all' or m.dataset_kind=p_kind)
      and m.node_id in(select n.node_id from targets n)
    group by m.node_id
  ), decorated as materialized (
    select n.node_id,n.code,jsonb_build_object(
      'nodeId',n.node_id,'parentNodeId',n.parent_node_id,'code',n.code,'taxonomy',n.taxonomy,
      'count',coalesce(c.count,0),'directCount',coalesce(c.direct_count,0),
      'hasChildren',exists(select 1 from private.portal_navigation_node_v1 child where child.parent_node_id=n.node_id
        and (child.source_file is not null or exists(select 1 from private.portal_navigation_membership_v1 m where m.node_id=child.node_id)))
    ) as value from targets n left join counted c on c.node_id=n.node_id
  ), paged as (
    select d.*,row_number() over(order by d.code collate "C",d.node_id collate "C") as rn
    from decorated d where d.node_id is distinct from p_parent_node_id
  ) select
    coalesce((select jsonb_agg(value order by rn) from paged where rn<=p_limit),'[]'::jsonb),
    (select case when count(*)>p_limit then (array_agg(node_id order by rn))[p_limit] else null end from paged),
    (select value from decorated where node_id=p_parent_node_id),
    (select jsonb_build_object('process',count(*) filter(where dataset_kind='process'),'flow',count(*) filter(where dataset_kind='flow')) from matched)
  into v_nodes,v_next,v_parent,v_totals;

  with recursive ancestors as (
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,1 as depth
    from private.portal_navigation_node_v1 n
    where n.node_id=(select p.parent_node_id from private.portal_navigation_node_v1 p where p.node_id=p_parent_node_id)
    union all
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,a.depth+1
    from ancestors a join private.portal_navigation_node_v1 n on n.node_id=a.parent_node_id
    where a.depth<32
  ) select coalesce(jsonb_agg(jsonb_build_object('nodeId',node_id,'parentNodeId',parent_node_id,'code',code,'taxonomy',taxonomy) order by depth desc),'[]'::jsonb)
    into v_ancestors from ancestors;

  loop
    v_result:=jsonb_build_object('schemaVersion','portal.public-navigation.v1','countBasis','public_versions',
      'dimension',p_dimension,'kind',p_kind,'totals',v_totals,'parent',v_parent,'ancestors',v_ancestors,'nodes',v_nodes,
      'nextCursor',case when v_next is null then null else private.portal_cursor_encode_v1(jsonb_build_object(
        'v',1,'fp',p_fingerprint,'dimension',p_dimension,'kind',p_kind,'parent',p_parent_node_id,'node',v_next)) end);
    exit when octet_length(v_result::text)<=65536;
    if jsonb_array_length(v_nodes)<=1 then
      raise exception using errcode='54000',message='Portal navigation response exceeds its byte budget';
    end if;
    v_nodes:=v_nodes-(jsonb_array_length(v_nodes)-1);
    v_next:=v_nodes->(jsonb_array_length(v_nodes)-1)->>'nodeId';
  end loop;
  return v_result;
end;
$function$;

create function private.portal_navigation_v1(
  p_kind text,p_query text,p_filters jsonb,p_dimension text,p_parent_node_id text,p_cursor text,p_limit integer
) returns jsonb language plpgsql stable parallel restricted set search_path=''
as $function$
declare
  v_query text:=lower(btrim(coalesce(p_query,'')));
  v_filters jsonb;
  v_limit integer:=coalesce(p_limit,100);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_node text;
begin
  if p_dimension is null or p_dimension not in ('classification','geography')
    or v_limit<1 or v_limit>500 then
    raise exception using errcode='22023',message='invalid portal request';
  end if;
  perform private.portal_validate_search_v3(p_kind,coalesce(p_query,''),coalesce(p_filters,'{}'::jsonb),'relevance',1);
  v_filters:=private.portal_normalize_filters_v1(p_filters);
  v_fingerprint:=encode(extensions.digest(convert_to(
    'portal-navigation-v1:' || (select asset_sha256 from private.portal_navigation_contract_v1 where contract_version=1) || ':' ||
    private.portal_query_fingerprint_v1(p_kind,v_query,v_filters,p_dimension || ':' || coalesce(p_parent_node_id,'')),
    'UTF8'),'sha256'),'hex');
  if p_cursor is not null then
    v_cursor:=private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null or jsonb_typeof(v_cursor)<>'object'
      or (select count(*) from jsonb_object_keys(v_cursor))<>6
      or v_cursor->>'v' is distinct from '1' or v_cursor->>'fp' is distinct from v_fingerprint
      or v_cursor->>'kind' is distinct from p_kind or v_cursor->>'dimension' is distinct from p_dimension
      or v_cursor->>'parent' is distinct from p_parent_node_id
      or coalesce(v_cursor->>'node','') !~ '^[a-z][a-z0-9-]*:[!-~]{1,96}$'
    then raise exception using errcode='22023',message='invalid portal request'; end if;
    v_cursor_node:=v_cursor->>'node';
  end if;
  return private.portal_navigation_impl_v1(p_kind,v_query,v_filters,p_dimension,p_parent_node_id,v_cursor_node,v_limit,v_fingerprint);
end;
$function$;

create function api.portal_navigation_v1(p_kind text,p_query text default '',p_filters jsonb default '{}',
  p_dimension text default 'classification',p_parent_node_id text default null,p_cursor text default null,p_limit integer default 100)
returns jsonb language plpgsql stable security definer
set search_path='' set statement_timeout='8s' set row_security='on'
as $function$
begin
  return private.portal_navigation_v1(p_kind,p_query,p_filters,p_dimension,p_parent_node_id,p_cursor,p_limit);
exception
  when sqlstate '22023' then raise exception using errcode='22023',message='invalid portal request';
  when query_canceled then raise exception using errcode='P0001',message='portal catalog unavailable';
  when others then raise exception using errcode='P0001',message='portal catalog unavailable';
end;
$function$;
alter function private.portal_navigation_version_matches_v3(text,jsonb,uuid,text) owner to portal_public_executor;
revoke all on function private.portal_navigation_version_matches_v3(text,jsonb,uuid,text) from public,anon,authenticated,service_role;
grant execute on function private.portal_navigation_version_matches_v3(text,jsonb,uuid,text) to portal_public_executor;
alter function private.portal_validate_search_v3(text,text,jsonb,text,integer) owner to portal_public_executor;
revoke all on function private.portal_validate_search_v3(text,text,jsonb,text,integer) from public,anon,authenticated,service_role;
grant execute on function private.portal_validate_search_v3(text,text,jsonb,text,integer) to portal_public_executor;
alter function private.portal_navigation_matched_versions_v1(text,text,jsonb) owner to portal_public_executor;
revoke all on function private.portal_navigation_matched_versions_v1(text,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function private.portal_navigation_matched_versions_v1(text,text,jsonb) to portal_public_executor;
alter function private.portal_navigation_impl_v1(text,text,jsonb,text,text,text,integer,text) owner to portal_public_executor;
revoke all on function private.portal_navigation_impl_v1(text,text,jsonb,text,text,text,integer,text) from public,anon,authenticated,service_role;
grant execute on function private.portal_navigation_impl_v1(text,text,jsonb,text,text,text,integer,text) to portal_public_executor;
alter function private.portal_navigation_v1(text,text,jsonb,text,text,text,integer) owner to portal_public_executor;
revoke all on function private.portal_navigation_v1(text,text,jsonb,text,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function private.portal_navigation_v1(text,text,jsonb,text,text,text,integer) to portal_public_executor;
alter function api.portal_navigation_v1(text,text,jsonb,text,text,text,integer) owner to portal_public_executor;
revoke all on function api.portal_navigation_v1(text,text,jsonb,text,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function api.portal_navigation_v1(text,text,jsonb,text,text,text,integer) to portal_public_executor;
grant execute on function private.assert_portal_navigation_contract_v1() to portal_public_executor;
grant execute on function api.portal_navigation_v1(text,text,jsonb,text,text,text,integer) to anon,authenticated;
revoke create on schema private,api from portal_public_executor,api_internal_executor;
revoke portal_public_executor,api_internal_executor from postgres;
commit;
