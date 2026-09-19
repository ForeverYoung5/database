CREATE OR REPLACE FUNCTION "private"."portal_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) RETURNS "void"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "private"."portal_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) TO "portal_public_executor";
