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
CREATE OR REPLACE FUNCTION private.portal_search_v3(p_kind text, p_query text, p_filters jsonb, p_sort text, p_cursor text, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE PARALLEL RESTRICTED
 SET search_path TO ''
AS $function$
declare
  v_query text;
  v_filters jsonb;
  v_sort text;
  v_limit integer := coalesce(p_limit, 20);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_rank text;
  v_cursor_id uuid;
  v_cursor_version text;
  v_kernel jsonb;
  v_next_cursor_payload jsonb;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();

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
  v_fingerprint := private.portal_query_fingerprint_v1(
    p_kind,
    v_query,
    v_filters,
    v_sort
  );
  if p_kind = 'process' then
  v_fingerprint := pg_catalog.encode(extensions.digest(pg_catalog.convert_to('composite-names-v2:' || v_fingerprint, 'UTF8'), 'sha256'), 'hex');
  end if;
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.portal_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'fp' <> v_fingerprint
       or v_cursor ->> 'kind' <> p_kind
       or coalesce(v_cursor ->> 'rankKey', '') = ''
       or coalesce(v_cursor ->> 'id', '')
         !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_rank := v_cursor ->> 'rankKey';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
    v_cursor_version := v_cursor ->> 'version';
    if v_sort = 'relevance'
       and v_cursor_rank !~ '^(0(\.\d+)?|1(\.0+)?)$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    elsif v_sort = 'modified_desc'
       and private.portal_datetime_v1(v_cursor_rank) is null then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  v_kernel := private.catalog_portal_search_v3_impl(
    p_kind,v_query,v_filters,v_sort,v_cursor_rank,v_cursor_id,v_cursor_version,v_limit,v_fingerprint
  );

  v_next_cursor_payload := nullif(
    v_kernel -> 'nextCursorPayload',
    'null'::jsonb
  );

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-search-page.v1',
    'kind', p_kind,
    'queryFingerprint', v_fingerprint,
    'items', coalesce(v_kernel -> 'items', '[]'::jsonb),
    'nextCursor', case when v_next_cursor_payload is null then null
      else private.portal_cursor_encode_v1(v_next_cursor_payload)
    end
  );
end;
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
end;
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
end;
$function$;

CREATE OR REPLACE FUNCTION api.portal_facets_v3(p_kind text, p_query text, p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '8s'
AS $function$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v3(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.portal_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
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

  return private.catalog_portal_facets_v3_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
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
end;
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
        candidate.dataset_kind, p_filters, candidate.id, candidate.version
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

alter function private.catalog_portal_candidate_rows_v3(text, text, uuid, text) owner to portal_public_executor;
alter function private.catalog_portal_facet_candidate_rows_v3(text, text, uuid, text) owner to portal_public_executor;
alter function private.catalog_portal_search_v3_impl(text, text, jsonb, text, text, uuid, text, integer, text) owner to portal_public_executor;
alter function private.catalog_portal_facets_v3_impl(text, text, uuid, text, jsonb, text) owner to portal_public_executor;

revoke all on function private.catalog_portal_candidate_rows_v3(text, text, uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_facet_candidate_rows_v3(text, text, uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_search_v3_impl(text, text, jsonb, text, text, uuid, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function private.catalog_portal_facets_v3_impl(text, text, uuid, text, jsonb, text) from public, anon, authenticated, service_role;

grant execute on function private.catalog_portal_candidate_rows_v3(text, text, uuid, text) to api_internal_executor, portal_public_executor;
grant execute on function private.catalog_portal_facet_candidate_rows_v3(text, text, uuid, text) to api_internal_executor, portal_public_executor;
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
