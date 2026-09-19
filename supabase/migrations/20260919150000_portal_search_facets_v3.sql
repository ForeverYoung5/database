-- Database #656: Portal Search/Facets V3 with navigation node filters.
--
-- V3 adds only an input boundary: `classificationNodeId`, `geographyNodeId` and
-- the matching `*Scope` selectors. The response shape stays
-- `portal.public-search-page.v2` / `portal.public-facets.v2`, and V2 plus the
-- Hybrid RPCs keep their exact signatures, behaviour and bytes.
--
-- Filtering runs inside the same matched-version predicate the search and facet
-- kernels already use, before their own ordering and limits, so a node filter
-- can never be applied to a page sample.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

grant portal_public_executor, api_internal_executor to postgres;
grant create on schema private, api to portal_public_executor, api_internal_executor;

-- The navigation boundary of a matched version. `subtree` is the default when a
-- node is given; a scope without a node is rejected by validation.
-- The closure already materialises every ancestor of every authored placement,
-- so a subtree scope is one node equality and a direct scope adds the authored
-- flag. No prefix or path arithmetic is involved.
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
set search_path = ''
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

create function private.catalog_portal_candidate_rows_v3(
  p_kind text,
  p_query text,
  p_exact_id uuid,
  p_like_pattern text
)
returns table(id uuid, version text, card jsonb, state_code integer, modified_at timestamptz)
language sql
stable
security definer
parallel restricted
set search_path = ''
set statement_timeout = '8s'
set row_security = 'on'
as $function$
  select candidate.id,
    candidate.version,
    candidate.card,
    candidate.state_code,
    candidate.modified_at
  from private.catalog_portal_candidate_rows_v2(
    p_kind, p_query, p_exact_id, p_like_pattern
  ) as candidate
$function$;

create function private.catalog_portal_facet_candidate_rows_v3(
  p_kind text,
  p_query text,
  p_exact_id uuid,
  p_like_pattern text
)
returns table(dataset_kind text, id uuid, version text, card jsonb)
language sql
stable
security definer
parallel restricted
set search_path = ''
set statement_timeout = '8s'
set row_security = 'on'
as $function$
  select candidate.dataset_kind,
    candidate.id,
    candidate.version,
    candidate.card
  from private.catalog_portal_facet_candidate_rows_v2(
    p_kind, p_query, p_exact_id, p_like_pattern
  ) as candidate
$function$;

-- V2 accepts only its own filter keys, so V3 validates the extended set itself
-- and hands the plain subset to the unchanged V2 validator and kernels.
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
  if p_filters is null or pg_catalog.jsonb_typeof(p_filters) <> 'object' then
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
end
$function$;

create function private.portal_search_v3(
  p_kind text,
  p_query text,
  p_filters jsonb,
  p_sort text,
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
  v_sort text;
  v_limit integer := coalesce(p_limit, 20);
  v_fingerprint text;
  v_result jsonb;
begin
  perform private.portal_validate_search_v3(
    p_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    coalesce(p_sort, 'relevance'),
    v_limit
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_sort := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'relevance')));

  -- The navigation filter is part of the request identity, so a cursor bound to
  -- a different branch can never be replayed.
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to(
      'portal-search-versions-v3:' || private.portal_query_fingerprint_v1(
        p_kind, v_query, v_filters, v_sort
      ),
      'UTF8'
    ),
    'sha256'
  ), 'hex');

  v_result := private.portal_search_v2(
    p_kind, p_query, p_filters, p_sort, p_cursor, p_limit
  );
  if pg_catalog.jsonb_typeof(v_result) = 'object' then
    v_result := pg_catalog.jsonb_set(
      v_result, '{queryFingerprint}', pg_catalog.to_jsonb(v_fingerprint)
    );
  end if;
  return v_result;
end
$function$;

create function api.portal_search_processes_v3(
  p_query text,
  p_filters jsonb default '{}'::jsonb,
  p_sort text default 'relevance',
  p_cursor text default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '8s'
as $function$
begin
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v3(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$function$;

create function api.portal_search_flows_v3(
  p_query text,
  p_filters jsonb default '{}'::jsonb,
  p_sort text default 'relevance',
  p_cursor text default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '8s'
as $function$
begin
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_search_v3(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$function$;

create function api.portal_facets_v3(
  p_kind text,
  p_query text,
  p_filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '8s'
as $function$
declare
  v_kind text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, 'all')));
  v_query text := coalesce(p_query, '');
  v_filters jsonb := private.portal_normalize_filters_v1(coalesce(p_filters, '{}'::jsonb));
  v_fingerprint text;
  v_result jsonb;
begin
  perform private.portal_validate_search_v3(v_kind, v_query, v_filters, 'relevance', 20);
  v_query := pg_catalog.lower(pg_catalog.btrim(v_query));
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to(
      'portal-facets-v3:' || private.portal_query_fingerprint_v1(
        v_kind, v_query, v_filters, 'facets'
      ),
      'UTF8'
    ),
    'sha256'
  ), 'hex');
  v_result := api.portal_facets_v2(v_kind, v_query, v_filters);
  if pg_catalog.jsonb_typeof(v_result) = 'object' then
    v_result := pg_catalog.jsonb_set(
      v_result, '{queryFingerprint}', pg_catalog.to_jsonb(v_fingerprint)
    );
  end if;
  return v_result;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$function$;

CREATE OR REPLACE FUNCTION private.catalog_portal_search_v3_impl(p_kind text, p_query text, p_filters jsonb, p_sort text, p_cursor_rank text, p_cursor_id uuid, p_cursor_version text, p_limit integer, p_query_fingerprint text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE PARALLEL RESTRICTED SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '8s'
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
declare
  v_items jsonb;
  v_next_cursor_payload jsonb;
  v_exact_id uuid;
  v_like_pattern text;
begin
  if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := p_query::uuid;
  end if;
  if p_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          p_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;
  -- Empty unfiltered browse pages do not require search facts for the whole
  -- catalog.  Order/cursor reduction happens before at most limit+1
  -- cards are hydrated.
  if p_query = ''
     and p_filters = '{}'::jsonb
     and p_sort in ('relevance', 'modified_desc', 'name_asc') then
    with portal_prefilter as materialized (
      select p_kind as dataset_kind,
        candidate.*,
        case when p_sort = 'name_asc' then case
          when nullif(candidate.card #>> '{names,0,value}', '') is not null
            and pg_catalog.length(
              candidate.card #>> '{names,0,value}'
            ) <= 500
            and pg_catalog.octet_length(
              candidate.card #>> '{names,0,value}'
            ) <= 2000
            and candidate.card #>> '{names,0,value}' !~ '[[:cntrl:]]'
            then candidate.card #>> '{names,0,value}'
          else '~unnamed:' || candidate.id::text
        end end as name_key
      from private.catalog_portal_candidate_rows_v3(
        p_kind,
        p_query,
        v_exact_id,
        v_like_pattern
      ) as candidate
      where private.portal_navigation_version_matches_v3(
        p_kind, p_filters, candidate.id, candidate.version
      )
    ), portal_after_cursor as materialized (
      select portal_prefilter.*
      from portal_prefilter
      where p_cursor_rank is null
        or case p_sort
          when 'relevance' then
            0::numeric < p_cursor_rank::numeric
            or (
              0::numeric = p_cursor_rank::numeric
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          when 'modified_desc' then
            portal_prefilter.modified_at < p_cursor_rank::timestamptz
            or (
              portal_prefilter.modified_at = p_cursor_rank::timestamptz
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          else
            pg_catalog.lower(portal_prefilter.name_key)
              > pg_catalog.lower(p_cursor_rank)
            or (
              pg_catalog.lower(portal_prefilter.name_key)
                = pg_catalog.lower(p_cursor_rank)
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
        end
    ), portal_ordered as materialized (
      select portal_after_cursor.*,
        pg_catalog.row_number() over (
          order by
            case when p_sort = 'modified_desc'
              then portal_after_cursor.modified_at end desc,
            case when p_sort = 'name_asc'
              then pg_catalog.lower(portal_after_cursor.name_key) end asc,
            portal_after_cursor.id asc,
            portal_after_cursor.version desc
        ) as page_rank
      from portal_after_cursor
      order by
        case when p_sort = 'modified_desc'
          then portal_after_cursor.modified_at end desc,
        case when p_sort = 'name_asc'
          then pg_catalog.lower(portal_after_cursor.name_key) end asc,
        portal_after_cursor.id asc,
        portal_after_cursor.version desc
      limit p_limit + 1
    ), portal_decorated as materialized (
      select portal_ordered.*
      from portal_ordered
    )
    select
      coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', p_kind,
            'id', portal_decorated.id::text,
            'version', portal_decorated.version
          ),
          'accessLevel', portal_decorated.card -> 'accessLevel',
          'capabilities', portal_decorated.card -> 'capabilities',
          'names', portal_decorated.card -> 'names',
          'summary', portal_decorated.card -> 'summary',
          'geography', portal_decorated.card -> 'geography',
          'referenceYear', portal_decorated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            portal_decorated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            'kind', 'lexical',
            'score', 0::numeric,
            'reasonCodes', '[]'::jsonb
          )
        ) order by portal_decorated.page_rank
      ) filter (where portal_decorated.page_rank <= p_limit), '[]'::jsonb),
      case when max(portal_decorated.page_rank) > p_limit then
        (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'v', 1,
          'fp', p_query_fingerprint,
          'rankKey', case p_sort
            when 'relevance' then '0'
            when 'modified_desc' then pg_catalog.to_char(
              portal_decorated.modified_at at time zone 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            )
            else pg_catalog.lower(portal_decorated.name_key)
          end,
          'kind', p_kind,
          'id', portal_decorated.id::text,
          'version', portal_decorated.version
        ) order by portal_decorated.page_rank)
          filter (where portal_decorated.page_rank = p_limit)) -> 0
      else null end
    into v_items, v_next_cursor_payload
    from portal_decorated;

    return pg_catalog.jsonb_build_object(
      'items', v_items,
      'nextCursorPayload', v_next_cursor_payload
    );
  end if;


  with portal_prefilter as materialized (
    select p_kind as dataset_kind,
      candidate.*
    from private.catalog_portal_candidate_rows_v3(
      p_kind,
      p_query,
      v_exact_id,
      v_like_pattern
    ) as candidate
    where private.portal_navigation_version_matches_v3(
      p_kind, p_filters, candidate.id, candidate.version
    )
  ), portal_facts as materialized (
    select portal_prefilter.*,
      private.catalog_portal_card_facts_v1(
        portal_prefilter.card,
        p_filters,
        p_query
      ) as facts
    from portal_prefilter
  ), portal_scored as materialized (
    select portal_facts.*,
      case
        when nullif(portal_facts.facts ->> 'nameKey', '') is not null
          and pg_catalog.length(portal_facts.facts ->> 'nameKey') <= 500
          and pg_catalog.octet_length(portal_facts.facts ->> 'nameKey') <= 2000
          and portal_facts.facts ->> 'nameKey' !~ '[[:cntrl:]]'
          then portal_facts.facts ->> 'nameKey'
        else '~unnamed:' || portal_facts.id::text
      end as name_key,
      case
        when p_query = '' then 0::numeric
        when pg_catalog.lower(portal_facts.id::text) = p_query then 1::numeric
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then 0.98::numeric
        when (portal_facts.facts ->> 'nameExact')::boolean then 0.95::numeric
        when (portal_facts.facts ->> 'classificationExact')::boolean
          then 0.92::numeric
        when p_query <> '' then 0.70::numeric
        else 0::numeric
      end as score,
      case
        when pg_catalog.lower(portal_facts.id::text) = p_query
          then pg_catalog.jsonb_build_array('exact_id')
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then pg_catalog.jsonb_build_array('cas')
        when (portal_facts.facts ->> 'nameExact')::boolean
          or (portal_facts.facts ->> 'nameContains')::boolean
          then pg_catalog.jsonb_build_array('name')
        when (portal_facts.facts ->> 'classificationExact')::boolean
          or (portal_facts.facts ->> 'classificationContains')::boolean
          then pg_catalog.jsonb_build_array('classification')
        when p_query <> '' then pg_catalog.jsonb_build_array('full_text')
        else '[]'::jsonb
      end as reason_codes
    from portal_facts
  ), portal_filtered as materialized (
    select portal_scored.*,
      case p_sort
        when 'relevance' then portal_scored.score::text
        when 'modified_desc' then pg_catalog.to_char(
          portal_scored.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
        else pg_catalog.lower(portal_scored.name_key)
      end as rank_key
    from portal_scored
    where (p_query = '' or portal_scored.score > 0)
      and (
        not (p_filters ? 'accessLevel')
        or portal_scored.facts ->> 'accessLevel' = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'geographyCode',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or (portal_scored.facts ->> 'classificationFilterMatch')::boolean
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (portal_scored.facts ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (portal_scored.facts ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), portal_after_cursor as materialized (
    select portal_filtered.*
    from portal_filtered
    where p_cursor_rank is null
      or case p_sort
        when 'relevance' then
          portal_filtered.score < p_cursor_rank::numeric
          or (
            portal_filtered.score = p_cursor_rank::numeric
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        when 'modified_desc' then
          portal_filtered.modified_at < p_cursor_rank::timestamptz
          or (
            portal_filtered.modified_at = p_cursor_rank::timestamptz
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        else
          pg_catalog.lower(portal_filtered.name_key) > pg_catalog.lower(p_cursor_rank)
          or (
            pg_catalog.lower(portal_filtered.name_key) = pg_catalog.lower(p_cursor_rank)
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
      end
  ), portal_ordered as materialized (
    select portal_after_cursor.*,
      pg_catalog.row_number() over (
        order by
          case when p_sort = 'relevance' then portal_after_cursor.score end desc,
          case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
          case when p_sort = 'name_asc'
            then pg_catalog.lower(portal_after_cursor.name_key) end asc,
          portal_after_cursor.id asc,
          portal_after_cursor.version desc
      ) as page_rank
    from portal_after_cursor
    order by
      case when p_sort = 'relevance' then portal_after_cursor.score end desc,
      case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
      case when p_sort = 'name_asc'
        then pg_catalog.lower(portal_after_cursor.name_key) end asc,
      portal_after_cursor.id asc,
      portal_after_cursor.version desc
    limit p_limit + 1
  ), portal_hydrated as materialized (
    select portal_ordered.*
    from portal_ordered
  )
  select
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'key', pg_catalog.jsonb_build_object(
          'kind', p_kind,
          'id', portal_hydrated.id::text,
          'version', portal_hydrated.version
        ),
        'accessLevel', portal_hydrated.card -> 'accessLevel',
        'capabilities', portal_hydrated.card -> 'capabilities',
        'names', portal_hydrated.card -> 'names',
        'summary', portal_hydrated.card -> 'summary',
        'geography', portal_hydrated.card -> 'geography',
        'referenceYear', portal_hydrated.card -> 'referenceYear',
        'modifiedAt', pg_catalog.to_char(
          portal_hydrated.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        ),
        'match', pg_catalog.jsonb_build_object(
          'kind', case when portal_hydrated.reason_codes
            ?| array['exact_id', 'cas', 'classification']
            then 'identifier' else 'lexical' end,
          'score', portal_hydrated.score,
          'reasonCodes', portal_hydrated.reason_codes
        )
      ) order by portal_hydrated.page_rank
    ) filter (where portal_hydrated.page_rank <= p_limit), '[]'::jsonb),
    case when max(portal_hydrated.page_rank) > p_limit then
      (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'v', 1,
        'fp', p_query_fingerprint,
        'rankKey', portal_hydrated.rank_key,
        'kind', p_kind,
        'id', portal_hydrated.id::text,
        'version', portal_hydrated.version
      ) order by portal_hydrated.page_rank)
        filter (where portal_hydrated.page_rank = p_limit)) -> 0
    else null end
  into v_items, v_next_cursor_payload
  from portal_hydrated;

  return pg_catalog.jsonb_build_object(
    'items', v_items,
    'nextCursorPayload', v_next_cursor_payload
  );
end
$function$;

CREATE OR REPLACE FUNCTION private.catalog_portal_facets_v3_impl(p_kind text, p_query text, p_exact_id uuid, p_like_pattern text, p_filters jsonb, p_query_fingerprint text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE PARALLEL RESTRICTED SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '8s'
 SET plan_cache_mode TO 'force_custom_plan'
 SET row_security TO 'on'
AS $function$
  with matched as materialized (
    select candidate.*
    from private.catalog_portal_facet_candidate_rows_v3(
      p_kind,
      p_query,
      p_exact_id,
      p_like_pattern
    ) as candidate
    where private.portal_navigation_version_matches_v3(
        p_kind, p_filters, candidate.id, candidate.version
      )
      and (
        not (p_filters ? 'accessLevel')
        or candidate.card ->> 'accessLevel' = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card #>> '{geography,code}',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or exists (
          select 1
          from pg_catalog.jsonb_array_elements(
            candidate.card -> 'classifications'
          ) as classification(item)
          where pg_catalog.lower(pg_catalog.btrim(
            classification.item ->> 'code'
          )) = p_filters ->> 'classification'
        )
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (candidate.card ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (candidate.card ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), facet_values as materialized (
    select 'kind'::text as group_id,
      1 as group_order,
      matched.dataset_kind as value,
      matched.dataset_kind as label
    from matched
    union all
    select 'accessLevel',
      2,
      matched.card ->> 'accessLevel',
      matched.card ->> 'accessLevel'
    from matched
    union all
    select 'geography',
      3,
      pg_catalog.lower(pg_catalog.btrim(
        matched.card #>> '{geography,code}'
      )),
      matched.card #>> '{geography,code}'
    from matched
    union all
    select 'referenceYear',
      4,
      pg_catalog.btrim(matched.card ->> 'referenceYear'),
      pg_catalog.btrim(matched.card ->> 'referenceYear')
    from matched
    union all
    select 'processSubtype',
      5,
      pg_catalog.lower(pg_catalog.btrim(
        matched.card ->> 'processSubtype'
      )),
      matched.card ->> 'processSubtype'
    from matched
    where matched.dataset_kind = 'process'
    union all
    select 'source',
      6,
      pg_catalog.lower(pg_catalog.btrim(matched.card ->> 'source')),
      matched.card ->> 'source'
    from matched
  ), counts as materialized (
    select group_id,
      group_order,
      value,
      pg_catalog.min(value) as label,
      pg_catalog.count(*) as value_count
    from facet_values
    where nullif(pg_catalog.btrim(value), '') is not null
      and pg_catalog.length(value) <= 128
      and pg_catalog.octet_length(value) <= 512
    group by group_id, group_order, value
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v2',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
$function$;

alter function private.portal_navigation_version_matches_v3(text, jsonb, uuid, text) owner to api_internal_executor;
alter function private.catalog_portal_candidate_rows_v3(text, text, uuid, text) owner to portal_public_executor;
alter function private.catalog_portal_facet_candidate_rows_v3(text, text, uuid, text) owner to portal_public_executor;
alter function private.catalog_portal_search_v3_impl(text, text, jsonb, text, text, uuid, text, integer, text) owner to api_internal_executor;
alter function private.catalog_portal_facets_v3_impl(text, text, uuid, text, jsonb, text) owner to api_internal_executor;

revoke all on function private.portal_navigation_version_matches_v3(text, jsonb, uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_candidate_rows_v3(text, text, uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_facet_candidate_rows_v3(text, text, uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_search_v3_impl(text, text, jsonb, text, text, uuid, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_facets_v3_impl(text, text, uuid, text, jsonb, text) from public, anon, authenticated, service_role;

grant execute on function private.portal_navigation_version_matches_v3(text, jsonb, uuid, text) to api_internal_executor;
grant execute on function private.catalog_portal_candidate_rows_v3(text, text, uuid, text) to api_internal_executor;
grant execute on function private.catalog_portal_facet_candidate_rows_v3(text, text, uuid, text) to api_internal_executor;
grant execute on function private.catalog_portal_search_v3_impl(text, text, jsonb, text, text, uuid, text, integer, text) to portal_public_executor;
grant execute on function private.catalog_portal_facets_v3_impl(text, text, uuid, text, jsonb, text) to portal_public_executor;

alter function private.portal_validate_search_v3(text, text, jsonb, text, integer) owner to api_internal_executor;
alter function private.portal_search_v3(text, text, jsonb, text, text, integer) owner to portal_public_executor;
alter function api.portal_search_processes_v3(text, jsonb, text, text, integer) owner to portal_public_executor;
alter function api.portal_search_flows_v3(text, jsonb, text, text, integer) owner to portal_public_executor;
alter function api.portal_facets_v3(text, text, jsonb) owner to portal_public_executor;

revoke all on function private.portal_validate_search_v3(text, text, jsonb, text, integer)
  from public, anon, authenticated, service_role, portal_public_executor;
revoke all on function private.portal_search_v3(text, text, jsonb, text, text, integer)
  from public, anon, authenticated, service_role;
revoke all on function api.portal_search_processes_v3(text, jsonb, text, text, integer) from public;
revoke all on function api.portal_search_flows_v3(text, jsonb, text, text, integer) from public;
revoke all on function api.portal_facets_v3(text, text, jsonb) from public;

-- The v3 facades run as the public executor, so it needs the same execute bit
-- that the internal executor has; browser roles stay revoked.
grant execute on function private.portal_validate_search_v3(text, text, jsonb, text, integer)
  to api_internal_executor, portal_public_executor;
grant execute on function private.portal_search_v3(text, text, jsonb, text, text, integer) to portal_public_executor;
grant all on function api.portal_search_processes_v3(text, jsonb, text, text, integer) to anon, authenticated;
grant all on function api.portal_search_flows_v3(text, jsonb, text, text, integer) to anon, authenticated;
grant all on function api.portal_facets_v3(text, text, jsonb) to anon, authenticated;

reset role;
revoke create on schema private, api from api_internal_executor, portal_public_executor;
revoke api_internal_executor, portal_public_executor from postgres;

commit;
