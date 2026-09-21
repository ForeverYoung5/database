CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_replace_flow_reference"("p_before" "jsonb", "p_reference" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_entry jsonb := p_before #> '{flowDataSet,flowProperties,flowProperty}';
begin
  if v_entry is null or p_reference is null then
    return null;
  end if;
  if jsonb_typeof(v_entry) = 'array' then
    if jsonb_array_length(v_entry) <> 1 or coalesce(v_entry->0->>'@dataSetInternalID', '') <> '1' then
      return null;
    end if;
    return jsonb_set(p_before, '{flowDataSet,flowProperties,flowProperty,0,referenceToFlowPropertyDataSet}', p_reference, false);
  end if;
  if jsonb_typeof(v_entry) <> 'object' or coalesce(v_entry->>'@dataSetInternalID', '') <> '1' then
    return null;
  end if;
  return jsonb_set(p_before, '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet}', p_reference, false);
end
$$;

ALTER FUNCTION "private"."dataset_alias_v2_replace_flow_reference"("p_before" "jsonb", "p_reference" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_replace_flow_reference"("p_before" "jsonb", "p_reference" "jsonb") FROM PUBLIC;
