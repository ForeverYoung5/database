CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
declare
  v_index integer := coalesce((p_exchange->>'index')::integer, -1);
  v_exchanges jsonb := p_before #> '{processDataSet,exchanges,exchange}';
  v_entry jsonb;
  v_after text;
begin
  if v_index < 0 or jsonb_typeof(v_exchanges) <> 'array' or v_index >= jsonb_array_length(v_exchanges) then
    return null;
  end if;
  v_entry := v_exchanges->v_index;
  if jsonb_typeof(v_entry) <> 'object' then
    return null;
  end if;
  -- Absolute-uncertainty fields are outside this profile: only the relative uncertainty the audited
  -- exchanges actually carry may be present.
  if v_entry ?| array['minimumAmount', 'maximumAmount', 'standardDeviation95In', 'variance', 'standardDeviation'] then
    return null;
  end if;
  if coalesce(v_entry->>'@dataSetInternalID', '') <> coalesce(p_exchange->>'internal_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@refObjectId', '') <> coalesce(p_exchange->>'flow_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@version', '') <> coalesce(p_exchange->>'flow_version', '')
    or coalesce(v_entry->>'exchangeDirection', '') <> coalesce(p_exchange->>'direction', '')
    or v_entry->>'meanAmount' is distinct from p_exchange->>'before_literal'
    or v_entry->>'resultingAmount' is distinct from p_exchange->>'before_literal' then
    return null;
  end if;
  -- The reviewed source number is bound through the stored source comment, exactly as the Time
  -- profile binds its functional unit: the comment must exist and carry the declared number as a
  -- whole numeric token, so an exchange without its reviewed source comment fails closed.
  if coalesce(v_entry->>'generalComment', '') !~ ('(^|[^0-9])' || coalesce(p_exchange->>'source_exchange_number', '') || '([^0-9]|$)') then
    return null;
  end if;
  v_after := private.dataset_length_time_v1_multiply_amount(p_exchange->>'before_literal');
  if v_after is null or v_after is distinct from p_exchange->>'after_literal' then
    return null;
  end if;
  return jsonb_set(
    jsonb_set(p_before, array['processDataSet', 'exchanges', 'exchange', v_index::text, 'meanAmount'], to_jsonb(v_after), false),
    array['processDataSet', 'exchanges', 'exchange', v_index::text, 'resultingAmount'], to_jsonb(v_after), false);
end
$_$;

ALTER FUNCTION "private"."dataset_length_time_v1_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") FROM PUBLIC;
