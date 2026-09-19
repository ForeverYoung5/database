CREATE OR REPLACE FUNCTION "private"."sync_portal_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $_$
declare
  v_entry jsonb;
  v_entry_level integer;
  v_placement text;
  v_placements text[] := '{}'::text[];
  v_node text;
  v_code text;
  v_taxonomy text;
  v_raw_root text;
  v_geography text;
  v_matched integer := 0;
  v_raw_parent text;
begin
  insert into private.portal_navigation_versions_v1 (
    dataset_kind,id,version,access_level,geography_code,classification_codes,
    reference_year,process_subtype,source
  ) values (
    p_kind,p_id,p_version,p_card->>'accessLevel',
    lower(btrim(p_card#>>'{geography,code}')),
    array(select distinct lower(btrim(entry->>'code'))
      from jsonb_array_elements(coalesce(p_card->'classifications','[]'::jsonb)) entry
      where nullif(btrim(entry->>'code'),'') is not null),
    (p_card->>'referenceYear')::integer,
    lower(btrim(p_card->>'processSubtype')),lower(btrim(p_card->>'source'))
  ) on conflict (dataset_kind,id,version) do update set
    access_level=excluded.access_level,geography_code=excluded.geography_code,
    classification_codes=excluded.classification_codes,reference_year=excluded.reference_year,
    process_subtype=excluded.process_subtype,source=excluded.source
  where (portal_navigation_versions_v1.access_level,portal_navigation_versions_v1.geography_code,
    portal_navigation_versions_v1.classification_codes,portal_navigation_versions_v1.reference_year,
    portal_navigation_versions_v1.process_subtype,portal_navigation_versions_v1.source)
    is distinct from (excluded.access_level,excluded.geography_code,excluded.classification_codes,
      excluded.reference_year,excluded.process_subtype,excluded.source);
  delete from private.portal_navigation_membership_v1
    where dataset_kind=p_kind and id=p_id and version=p_version;
  for v_entry, v_entry_level in
    select distinct entry.value, (entry.ordinality - 1)::integer as level
    from pg_catalog.jsonb_array_elements(
      case pg_catalog.jsonb_typeof(p_card -> 'classifications')
        when 'array' then p_card -> 'classifications'
        else '[]'::jsonb
      end
    ) with ordinality as entry(value, ordinality)
    where pg_catalog.jsonb_typeof(entry.value) = 'object'
  loop
    v_node := private.portal_navigation_resolve_classification_v1(
      p_kind, v_entry -> 'system', v_entry, v_entry_level
    );
    if v_node is null then
      -- Keep the unknown/ambiguous authored code browsable under its own
      -- taxonomy instead of dropping it or guessing a node.
      v_code := private.portal_navigation_classification_code_v1(v_entry);
      if v_code is null then
        continue;
      end if;
      v_taxonomy := private.portal_navigation_raw_taxonomy_v1(v_entry -> 'system');
      if (p_kind='flow' and v_taxonomy='isic') or (p_kind='process' and v_taxonomy in ('cpc','elementary')) then
        v_taxonomy := 'unclassified';
      end if;
      v_raw_root := 'class:' || v_taxonomy || ':~raw';
      perform private.portal_navigation_ensure_virtual_v1(
        v_raw_root, 'classification', v_taxonomy, 'unmapped'
      );
      v_node := private.portal_navigation_raw_node_id_v1('class:' || v_taxonomy, p_kind || '|' || coalesce(v_entry->>'system','') || '|' || v_code);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_root, v_code, v_taxonomy, 'classification', null, null,
        pg_catalog.jsonb_build_object(
          'en', v_code, 'zh-CN', v_code, 'de', v_code, 'fr', v_code
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
    v_matched := v_matched + 1;
    v_placements := pg_catalog.array_append(v_placements, v_node);
  end loop;

  if v_matched = 0 then
    perform private.portal_navigation_ensure_virtual_v1(
      'class:unclassified', 'classification', 'unclassified', 'unclassified'
    );
    v_placements := pg_catalog.array_append(v_placements, 'class:unclassified');
  end if;

  v_geography := private.portal_navigation_geography_code_v1(p_kind, p_card);
  if v_geography is not null then
    v_node := 'geo:' || pg_catalog.lower(v_geography);
    if not exists(select 1 from private.portal_navigation_node_v1 n where n.node_id=v_node and n.dimension='geography') then
      v_node := coalesce(private.portal_navigation_resolve_alias_v1('geography',v_geography),v_node);
    end if;
    if not exists (
      select 1
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_node and node.dimension = 'geography'
    ) then
      perform private.portal_navigation_ensure_virtual_v1(
        'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
      );
      v_raw_parent := 'geo:unmapped';
      -- This verified code family is only a containing province, never proof of
      -- a particular city boundary or geographic precision.
      if upper(v_geography) ~ '^CN-[A-Z]{2}-[A-Z0-9-]+$' then
        select node.node_id into v_raw_parent from private.portal_navigation_node_v1 node
        where node.node_id='geo:' || lower(split_part(v_geography,'-',1)||'-'||split_part(v_geography,'-',2))
          and node.parent_node_id='geo:cn';
      end if;
      v_raw_parent := coalesce(v_raw_parent,'geo:unmapped');
      v_node := private.portal_navigation_raw_node_id_v1('geo', v_geography);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_parent, pg_catalog.upper(v_geography), 'unmapped', 'geography',
        null, null,
        pg_catalog.jsonb_build_object(
          'en', pg_catalog.upper(v_geography), 'zh-CN', pg_catalog.upper(v_geography),
          'de', pg_catalog.upper(v_geography), 'fr', pg_catalog.upper(v_geography)
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
  else
    perform private.portal_navigation_ensure_virtual_v1(
      'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
    );
    v_node := 'geo:unmapped';
  end if;
  v_placements := pg_catalog.array_append(v_placements, v_node);

  -- Materialise every ancestor of every authored placement, so a branch count is
  -- one grouped read instead of a per-node descendant search. A closure row is
  -- `direct` only when the authored placement is exactly that node.
  with recursive ancestors as (
    select n.node_id as leaf,n.parent_node_id as ancestor
    from private.portal_navigation_node_v1 n where n.node_id=any(v_placements)
    union all
    select a.leaf,n.parent_node_id from ancestors a
    join private.portal_navigation_node_v1 n on n.node_id=a.ancestor
    where a.ancestor is not null
  ) select coalesce(array_agg(distinct placement), '{}'::text[]) into v_placements
    from unnest(v_placements) placement
    where not exists(select 1 from ancestors a where a.ancestor=placement);

  foreach v_placement in array v_placements
  loop
    insert into private.portal_navigation_membership_v1 (
      dataset_kind, id, version, dimension, node_id, direct
    )
    with recursive chain as (
      select node.node_id,
        node.parent_node_id,
        node.dimension
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_placement
      union all
      select parent.node_id,
        parent.parent_node_id,
        parent.dimension
      from private.portal_navigation_node_v1 as parent
      join chain on parent.node_id = chain.parent_node_id
    )
    select p_kind, p_id, p_version, chain.dimension, chain.node_id,
      chain.node_id = v_placement
    from chain
    on conflict (dataset_kind,id,version,dimension,node_id) do update
      set direct=private.portal_navigation_membership_v1.direct or excluded.direct;
  end loop;
end;
$_$;

ALTER FUNCTION "private"."sync_portal_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."sync_portal_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."sync_portal_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") TO "postgres";
