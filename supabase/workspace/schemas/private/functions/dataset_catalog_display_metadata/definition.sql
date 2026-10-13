CREATE OR REPLACE FUNCTION "private"."dataset_catalog_display_metadata"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select pg_catalog.jsonb_build_object(
    'location',case p_kind
      when 'process' then p_json #>> '{processDataSet,processInformation,geography,locationOfOperationSupplyOrProduction,@location}'
      when 'flow' then p_json #>> '{flowDataSet,flowInformation,geography,locationOfSupply,@location}'
      when 'lifecyclemodel' then p_json #>> '{lifeCycleModelDataSet,lifeCycleModelInformation,geography,locationOfOperationSupplyOrProduction,@location}' else null end,
    'reference_year',case p_kind
      when 'process' then p_json #>> '{processDataSet,processInformation,time,common:referenceYear}'
      when 'flow' then p_json #>> '{flowDataSet,flowInformation,time,common:referenceYear}'
      when 'lifecyclemodel' then p_json #>> '{lifeCycleModelDataSet,lifeCycleModelInformation,time,common:referenceYear}' else null end,
    'type_of_data_set',case p_kind
      when 'process' then p_json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}'
      when 'flow' then p_json #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' else null end
  );
$$;

ALTER FUNCTION "private"."dataset_catalog_display_metadata"("p_kind" "text", "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_catalog_display_metadata"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;
