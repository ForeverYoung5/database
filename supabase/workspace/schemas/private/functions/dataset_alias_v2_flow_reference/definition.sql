CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_flow_reference"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when jsonb_typeof(p_payload #> '{flowDataSet,flowProperties,flowProperty}') = 'array'
      and jsonb_array_length(p_payload #> '{flowDataSet,flowProperties,flowProperty}') = 1
      and coalesce(p_payload #>> '{flowDataSet,flowProperties,flowProperty,0,@dataSetInternalID}', '') = '1'
      then p_payload #> '{flowDataSet,flowProperties,flowProperty,0,referenceToFlowPropertyDataSet}'
    when jsonb_typeof(p_payload #> '{flowDataSet,flowProperties,flowProperty}') = 'object'
      and coalesce(p_payload #>> '{flowDataSet,flowProperties,flowProperty,@dataSetInternalID}', '') = '1'
      then p_payload #> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet}'
    else null
  end
$$;

ALTER FUNCTION "private"."dataset_alias_v2_flow_reference"("p_payload" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_flow_reference"("p_payload" "jsonb") FROM PUBLIC;
