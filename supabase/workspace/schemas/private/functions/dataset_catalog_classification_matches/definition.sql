CREATE OR REPLACE FUNCTION "private"."dataset_catalog_classification_matches"("p_kind" "text", "p_json" "jsonb", "p_selectors" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'pg_catalog', 'pg_temp'
    AS $_$
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
$_$;

ALTER FUNCTION "private"."dataset_catalog_classification_matches"("p_kind" "text", "p_json" "jsonb", "p_selectors" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_catalog_classification_matches"("p_kind" "text", "p_json" "jsonb", "p_selectors" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."dataset_catalog_classification_matches"("p_kind" "text", "p_json" "jsonb", "p_selectors" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "private"."dataset_catalog_classification_matches"("p_kind" "text", "p_json" "jsonb", "p_selectors" "jsonb") TO "next_public_search_executor";
