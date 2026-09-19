-- Database #656: Portal navigation RPC (api.portal_navigation_v1).
--
-- One page of one branch. Immediate children are returned completely for the
-- requested page: the response is bounded at 65536 UTF-8 bytes and fails closed
-- instead of silently truncating a flat tree.
--
-- Count basis is `public_versions`: distinct exact `(dataset_kind, id, version)`
-- identities matching `p_query` + `p_filters`. `count` is the node's subtree
-- (self included); `directCount` is the subset that authored exactly that node.
-- Duplicate authored paths inside one version, and repeated versions of one id,
-- never double count.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

grant portal_public_executor, api_internal_executor to postgres;
grant create on schema private, api to portal_public_executor, api_internal_executor;

-- The navigation cursor uses the same opaque encoder as search. The internal
-- executor writes the page, so it needs exactly that one helper's execute bit;
-- nothing else about the existing grants changes.
grant execute on function private.portal_cursor_encode_v1(jsonb) to api_internal_executor;

create function private.portal_navigation_validate_v1(
  p_kind text,
  p_query text,
  p_filters jsonb,
  p_dimension text,
  p_parent_node_id text,
  p_limit integer
)
returns void
language plpgsql
stable
parallel safe
set search_path = ''
as $function$
declare
  v_key text;
  v_allowed text[] := array[
    'accessLevel', 'geography', 'classification', 'referenceYearFrom',
    'referenceYearTo', 'source'
  ];
begin
  if p_kind not in ('process', 'flow', 'all')
     or p_query is null
     or pg_catalog.length(p_query) > 512
     or pg_catalog.octet_length(p_query) > 2048
     or p_query ~ '[[:cntrl:]]'
     or p_dimension not in ('classification', 'geography')
     or p_parent_node_id is not null and (
       pg_catalog.length(p_parent_node_id) > 128
       or p_parent_node_id !~ '^[a-z][a-z0-9-]*:[!-~]{1,96}$'
     )
     or p_limit is null
     or p_limit < 1
     or p_limit > 500
     or p_filters is null
     or pg_catalog.jsonb_typeof(p_filters) <> 'object'
     or pg_catalog.pg_column_size(p_filters) > 4096
     or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(p_filters)) > 7 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_kind in ('process', 'all') then
    v_allowed := pg_catalog.array_append(v_allowed, 'processSubtype');
  end if;
  for v_key in select pg_catalog.jsonb_object_keys(p_filters)
  loop
    if not (v_key = any (v_allowed)) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;
  if p_filters ? 'accessLevel'
     and (
       pg_catalog.jsonb_typeof(p_filters -> 'accessLevel') <> 'string'
       or p_filters ->> 'accessLevel' not in ('open', 'metadata_only')
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_filters ? 'processSubtype' and p_kind = 'flow' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_filters ? 'referenceYearFrom' and p_filters ? 'referenceYearTo'
     and (p_filters ->> 'referenceYearFrom')::integer
       > (p_filters ->> 'referenceYearTo')::integer then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
end
$function$;

-- Aggregate the public-version counts a branch page needs in two grouped reads:
-- once for the page's own branch and once for the requested parent.
create function private.portal_navigation_node_count_v1(
  p_dimension text,
  p_node_id text,
  p_kind text,
  p_query text,
  p_filters jsonb
)
returns table(node_count bigint, direct_count bigint)
language sql
stable
security definer
parallel restricted
set search_path = ''
set statement_timeout = '8s'
set plan_cache_mode = 'force_custom_plan'
set row_security = 'on'
as $function$
  with matched_versions as materialized (
    select projection.dataset_kind,
      projection.id,
      projection.version
    from private.portal_catalog_search_rows_v2 as projection
    where projection.dataset_kind = 'process'
      and (p_kind = 'all' or p_kind = 'process')
      and private.portal_card_matches_filters_v2(projection.card, p_filters)
    union all
    select projection.dataset_kind,
      projection.id,
      projection.version
    from private.portal_catalog_search_rows_v1 as projection
    where projection.dataset_kind = 'flow'
      and (p_kind = 'all' or p_kind = 'flow')
      and private.portal_card_matches_filters_v2(projection.card, p_filters)
  ), branch as materialized (
    select member.dataset_kind,
      member.id,
      member.version,
      member.direct
    from private.portal_navigation_membership_v1 as member
    join matched_versions
      on matched_versions.dataset_kind = member.dataset_kind
     and matched_versions.id = member.id
     and matched_versions.version = member.version
    where member.dimension = p_dimension
      and member.node_id = p_node_id
  )
  select pg_catalog.count(distinct (branch.dataset_kind, branch.id, branch.version)),
    pg_catalog.count(distinct (branch.dataset_kind, branch.id, branch.version))
      filter (where branch.direct)
  from branch
$function$;

create function private.portal_navigation_impl_v1(
  p_kind text,
  p_query text,
  p_filters jsonb,
  p_dimension text,
  p_parent_node_id text,
  p_cursor_node_id text,
  p_limit integer,
  p_fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
parallel restricted
set search_path = ''
set statement_timeout = '8s'
set plan_cache_mode = 'force_custom_plan'
set row_security = 'on'
as $function$
declare
  v_parent record;
  v_ancestors jsonb := '[]'::jsonb;
  v_nodes jsonb := '[]'::jsonb;
  v_totals jsonb;
  v_next text;
  v_parent_id text;
  v_parent_parent_id text;
  v_parent_code text;
  v_parent_taxonomy text;
  v_parent_count bigint := 0;
  v_parent_direct bigint := 0;
  v_guard text;
  v_result jsonb;
begin
  perform private.assert_portal_navigation_contract_v1();

  if p_parent_node_id is not null then
    select node.node_id, node.parent_node_id
    into v_parent
    from private.portal_navigation_node_v1 as node
    where node.node_id = p_parent_node_id
      and node.dimension = p_dimension;
    if v_parent.node_id is null then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_parent_id := v_parent.node_id;

    with recursive chain as (
      select node.node_id,
        node.parent_node_id,
        node.code,
        node.taxonomy,
        1 as depth
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_parent.parent_node_id
        and node.dimension = p_dimension
      union all
      select parent.node_id,
        parent.parent_node_id,
        parent.code,
        parent.taxonomy,
        chain.depth + 1
      from private.portal_navigation_node_v1 as parent
      join chain on parent.node_id = chain.parent_node_id
      where parent.dimension = p_dimension
        and chain.depth < 32
    )
    select coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'nodeId', chain.node_id,
        'parentNodeId', chain.parent_node_id,
        'code', chain.code,
        'taxonomy', chain.taxonomy
      ) order by chain.depth desc
    ), '[]'::jsonb)
    into v_ancestors
    from chain;
  end if;

  with matched_versions as materialized (
    select projection.dataset_kind,
      projection.id,
      projection.version
    from private.portal_catalog_search_rows_v2 as projection
    where projection.dataset_kind = 'process'
      and private.portal_card_matches_filters_v2(projection.card, p_filters)
    union all
    select projection.dataset_kind,
      projection.id,
      projection.version
    from private.portal_catalog_search_rows_v1 as projection
    where projection.dataset_kind = 'flow'
      and private.portal_card_matches_filters_v2(projection.card, p_filters)
  ), totals as (
    select pg_catalog.jsonb_build_object(
        'process', pg_catalog.count(distinct (matched_versions.id, matched_versions.version))
          filter (where matched_versions.dataset_kind = 'process'),
        'flow', pg_catalog.count(distinct (matched_versions.id, matched_versions.version))
          filter (where matched_versions.dataset_kind = 'flow')
      ) as value
    from matched_versions
  ), visible_versions as materialized (
    select matched_versions.dataset_kind,
      matched_versions.id,
      matched_versions.version
    from matched_versions
    where p_kind = 'all' or matched_versions.dataset_kind = p_kind
  ), leaf_nodes as materialized (
    select node.node_id, node.parent_node_id, node.code, node.taxonomy
    from private.portal_navigation_node_v1 as node
    where node.dimension = p_dimension
      and node.parent_node_id is not distinct from p_parent_node_id
      and (p_cursor_node_id is null or node.node_id > p_cursor_node_id)
    order by node.node_id
    limit p_limit + 1
  ), branch_counts as (
    select member.node_id,
      pg_catalog.count(distinct (member.dataset_kind, member.id, member.version)) as node_count,
      pg_catalog.count(distinct (member.dataset_kind, member.id, member.version))
        filter (where member.direct) as direct_count
    from private.portal_navigation_membership_v1 as member
    join visible_versions
      on visible_versions.dataset_kind = member.dataset_kind
     and visible_versions.id = member.id
     and visible_versions.version = member.version
    where member.dimension = p_dimension
      and member.node_id in (select leaf.node_id from leaf_nodes as leaf)
    group by member.node_id
  ), page as (
    select leaf.node_id,
      leaf.parent_node_id,
      leaf.code,
      leaf.taxonomy,
      coalesce(branch_counts.node_count, 0) as node_count,
      coalesce(branch_counts.direct_count, 0) as direct_count,
      exists (
        select 1
        from private.portal_navigation_node_v1 as child
        where child.parent_node_id = leaf.node_id
      ) as has_children,
      pg_catalog.row_number() over (order by leaf.node_id) as page_rank
    from leaf_nodes as leaf
    left join branch_counts on branch_counts.node_id = leaf.node_id
  )
  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'nodeId', page.node_id,
      'parentNodeId', page.parent_node_id,
      'code', page.code,
      'taxonomy', page.taxonomy,
      'count', page.node_count,
      'directCount', page.direct_count,
      'hasChildren', page.has_children
    ) order by page.page_rank
  ) filter (where page.page_rank <= p_limit), '[]'::jsonb),
  case when pg_catalog.max(page.page_rank) > p_limit then
    (pg_catalog.jsonb_agg(page.node_id order by page.page_rank)
      filter (where page.page_rank = p_limit)) -> 0
  else null end,
  (select totals.value from totals)
  into v_nodes, v_next, v_totals
  from page;

  v_parent_id := case when p_parent_node_id is null then null else v_parent_id end;

  if v_parent_id is not null then
    select node.parent_node_id, node.code, node.taxonomy
    into v_parent_parent_id, v_parent_code, v_parent_taxonomy
    from private.portal_navigation_node_v1 as node
    where node.node_id = v_parent_id;

    select parent_count.node_count, parent_count.direct_count
    into v_parent_count, v_parent_direct
    from private.portal_navigation_node_count_v1(
      p_dimension, v_parent_id, p_kind, p_query, p_filters
    ) as parent_count;
    v_parent_count := coalesce(v_parent_count, 0);
    v_parent_direct := coalesce(v_parent_direct, 0);
  end if;

  v_result := pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-navigation.v1',
    'countBasis', 'public_versions',
    'dimension', p_dimension,
    'kind', p_kind,
    'totals', coalesce(v_totals, pg_catalog.jsonb_build_object('process', 0, 'flow', 0)),
    'parent', case when p_parent_node_id is null then null else
      pg_catalog.jsonb_build_object(
        'nodeId', v_parent_id,
        'parentNodeId', v_parent_parent_id,
        'code', v_parent_code,
        'taxonomy', v_parent_taxonomy,
        'count', v_parent_count,
        'directCount', v_parent_direct,
        'hasChildren', exists (
          select 1 from private.portal_navigation_node_v1 as child
          where child.parent_node_id = v_parent_id
        )
      ) end,
    'ancestors', v_ancestors,
    'nodes', v_nodes,
    'nextCursor', case when v_next is null then null
      else private.portal_cursor_encode_v1(pg_catalog.jsonb_build_object(
        'v', 1,
        'fp', p_fingerprint,
        'dimension', p_dimension,
        'kind', p_kind,
        'parent', p_parent_node_id,
        'node', v_next
      ))
    end
  );

  if pg_catalog.octet_length(v_result::text) > 65536 then
    raise exception using
      errcode = '54000',
      message = 'Portal navigation page exceeded its response budget';
  end if;
  return v_result;
end
$function$;

create function private.portal_navigation_v1(
  p_kind text,
  p_query text,
  p_filters jsonb,
  p_dimension text,
  p_parent_node_id text,
  p_cursor text,
  p_limit integer
)
returns jsonb
language plpgsql
stable
parallel restricted
set search_path = ''
as $function$
declare
  v_query text;
  v_filters jsonb;
  v_limit integer := coalesce(p_limit, 100);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_node text;
begin
  perform private.portal_navigation_validate_v1(
    p_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    p_dimension,
    p_parent_node_id,
    v_limit
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to(
      'portal-navigation-v1:' || private.portal_query_fingerprint_v1(
        p_kind, v_query, v_filters, p_dimension || ':' || coalesce(p_parent_node_id, '')
      ),
      'UTF8'
    ),
    'sha256'
  ), 'hex');

  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'fp' <> v_fingerprint
       or v_cursor ->> 'dimension' <> p_dimension
       or v_cursor ->> 'kind' <> p_kind
       or v_cursor ->> 'parent' is distinct from p_parent_node_id
       or coalesce(v_cursor ->> 'node', '') !~ '^[a-z][a-z0-9-]*:[!-~]{1,96}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_node := v_cursor ->> 'node';
  end if;

  return private.portal_navigation_impl_v1(
    p_kind, v_query, v_filters, p_dimension, p_parent_node_id,
    v_cursor_node, v_limit, v_fingerprint
  );
end
$function$;

create function api.portal_navigation_v1(
  p_kind text,
  p_query text default '',
  p_filters jsonb default '{}'::jsonb,
  p_dimension text default 'classification',
  p_parent_node_id text default null,
  p_cursor text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '8s'
as $function$
begin
  return private.portal_navigation_v1(
    p_kind, p_query, p_filters, p_dimension, p_parent_node_id, p_cursor, p_limit
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$function$;

comment on function api.portal_navigation_v1(text, text, jsonb, text, text, text, integer) is
  'Anonymous, locator-free navigation page: one branch of the classification or geography vocabulary with public-version counts and complete keyset pagination.';

alter function private.portal_navigation_node_count_v1(text, text, text, text, jsonb) owner to portal_public_executor;
alter function private.portal_navigation_validate_v1(text, text, jsonb, text, text, integer) owner to api_internal_executor;
alter function private.portal_navigation_impl_v1(text, text, jsonb, text, text, text, integer, text) owner to api_internal_executor;
alter function private.portal_navigation_v1(text, text, jsonb, text, text, text, integer) owner to portal_public_executor;
alter function api.portal_navigation_v1(text, text, jsonb, text, text, text, integer) owner to portal_public_executor;

revoke all on function private.portal_navigation_validate_v1(text, text, jsonb, text, text, integer) from public, anon, authenticated, service_role;
revoke all on function private.portal_navigation_node_count_v1(text, text, text, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.portal_navigation_impl_v1(text, text, jsonb, text, text, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function private.portal_navigation_v1(text, text, jsonb, text, text, text, integer) from public, anon, authenticated, service_role;
revoke all on function api.portal_navigation_v1(text, text, jsonb, text, text, text, integer) from public;
revoke all on function api.portal_navigation_v1(text, text, jsonb, text, text, text, integer) from anon, authenticated;

grant execute on function private.portal_navigation_validate_v1(text, text, jsonb, text, text, integer)
  to api_internal_executor, portal_public_executor;
grant execute on function private.portal_navigation_node_count_v1(text, text, text, text, jsonb) to api_internal_executor;
grant execute on function private.portal_navigation_impl_v1(text, text, jsonb, text, text, text, integer, text)
  to api_internal_executor, portal_public_executor;
grant execute on function private.portal_navigation_v1(text, text, jsonb, text, text, text, integer) to portal_public_executor;
grant all on function api.portal_navigation_v1(text, text, jsonb, text, text, text, integer) to anon;
grant all on function api.portal_navigation_v1(text, text, jsonb, text, text, text, integer) to authenticated;

reset role;
revoke create on schema private, api from api_internal_executor, portal_public_executor;
revoke api_internal_executor, portal_public_executor from postgres;

commit;
