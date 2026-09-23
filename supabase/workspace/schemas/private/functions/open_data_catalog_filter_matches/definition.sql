CREATE OR REPLACE FUNCTION "private"."open_data_catalog_filter_matches"("p_dataset_kind" "text", "p_json" "jsonb", "p_filter_condition" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'pg_catalog', 'pg_temp'
    AS $$
declare
  v_filter jsonb := coalesce(p_filter_condition, '{}'::jsonb);
  v_type_filter text;
  v_type_filters text[];
  v_as_input boolean;
  v_classification_filter jsonb := '[]'::jsonb;
begin
  if p_dataset_kind = 'process' then
    v_type_filter := nullif(btrim(v_filter ->> 'typeOfDataSet'), '');
    v_filter := v_filter - 'typeOfDataSet';
    return p_json @> v_filter
      and (
        v_type_filter is null
        or v_type_filter = 'all'
        or p_json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}' = v_type_filter
      );
  end if;

  if p_dataset_kind <> 'flow' then
    return p_json @> v_filter;
  end if;

  v_type_filter := nullif(btrim(v_filter ->> 'flowType'), '');
  v_type_filters := case when v_type_filter is null then null else string_to_array(v_type_filter, ',') end;
  v_filter := v_filter - 'flowType';

  if v_filter ? 'asInput' then
    v_as_input := nullif(btrim(v_filter ->> 'asInput'), '')::boolean;
  end if;
  v_filter := v_filter - 'asInput';

  if jsonb_typeof(v_filter -> 'classification') = 'array' then
    v_classification_filter := v_filter -> 'classification';
  end if;
  v_filter := v_filter - 'classification';

  return p_json @> v_filter
    and (
      v_type_filters is null
      or p_json #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' = any(v_type_filters)
    )
    and (
      v_as_input is null
      or not v_as_input
      or not p_json @> '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"classificationInformation":{"common:elementaryFlowCategorization":{"common:category":[{"#text":"Emissions","@level":"0"}]}}}}}}'::jsonb
    )
    and (
      jsonb_array_length(v_classification_filter) = 0
      or exists (
        select 1
        from jsonb_array_elements(v_classification_filter) selected(item)
        where (
          selected.item ->> 'scope' = 'elementary'
          and exists (
            select 1
            from jsonb_array_elements(
              case jsonb_typeof(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:elementaryFlowCategorization,common:category}')
                when 'array' then p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:elementaryFlowCategorization,common:category}'
                when 'object' then jsonb_build_array(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:elementaryFlowCategorization,common:category}')
                else '[]'::jsonb
              end
            ) category(item)
            where category.item ->> '@catId' = selected.item ->> 'code'
          )
        ) or (
          selected.item ->> 'scope' = 'classification'
          and exists (
            select 1
            from jsonb_array_elements(
              case jsonb_typeof(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class}')
                when 'array' then p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class}'
                when 'object' then jsonb_build_array(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class}')
                else '[]'::jsonb
              end
            ) classification(item)
            where classification.item ->> '@classId' = selected.item ->> 'code'
          )
        )
      )
    );
end;
$$;

ALTER FUNCTION "private"."open_data_catalog_filter_matches"("p_dataset_kind" "text", "p_json" "jsonb", "p_filter_condition" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."open_data_catalog_filter_matches"("p_dataset_kind" "text", "p_json" "jsonb", "p_filter_condition" "jsonb") FROM PUBLIC;
