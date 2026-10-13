CREATE OR REPLACE FUNCTION "private"."dataset_catalog_filter_matches"("p_kind" "text", "p_json" "jsonb", "p_filter" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'pg_catalog', 'pg_temp'
    AS $$
declare
  filter_json jsonb := coalesce(p_filter,'{}'::jsonb);
  type_filter text; flow_reference jsonb; exchanges jsonb;
begin
  p_kind := coalesce(p_kind, case when p_json ? 'processDataSet' then 'process' when p_json ? 'flowDataSet' then 'flow' when p_json ? 'lifeCycleModelDataSet' then 'lifecyclemodel' when p_json ? 'contactDataSet' then 'contact' when p_json ? 'sourceDataSet' then 'source' when p_json ? 'unitGroupDataSet' then 'unitgroup' when p_json ? 'flowPropertyDataSet' then 'flowproperty' else null end);
  perform private.dataset_catalog_filter_validate(filter_json);
  if filter_json ?| array['datasetId','sourceEntityKinds'] then
    raise exception using errcode='22023',message='identity filters require an explicitly bound catalog or UUID route';
  end if;
  if not private.dataset_catalog_classification_matches(p_kind,p_json,filter_json->'classification') then return false; end if;
  filter_json := filter_json - 'classification';
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

ALTER FUNCTION "private"."dataset_catalog_filter_matches"("p_kind" "text", "p_json" "jsonb", "p_filter" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_catalog_filter_matches"("p_kind" "text", "p_json" "jsonb", "p_filter" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."dataset_catalog_filter_matches"("p_kind" "text", "p_json" "jsonb", "p_filter" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "private"."dataset_catalog_filter_matches"("p_kind" "text", "p_json" "jsonb", "p_filter" "jsonb") TO "next_public_search_executor";
