CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_index integer := coalesce((p_exchange->>'index')::integer, -1);
  v_exchanges jsonb := p_before #> '{processDataSet,exchanges,exchange}';
  v_entry jsonb;
  v_after_mean text;
  v_after_resulting text;
begin
  if v_index < 0 or jsonb_typeof(v_exchanges) <> 'array' or v_index >= jsonb_array_length(v_exchanges) then
    return null;
  end if;
  v_entry := v_exchanges->v_index;
  if not private.dataset_alias_v2_exchange_keys_ok(v_entry) then
    return null;
  end if;
  if coalesce(v_entry->>'@dataSetInternalID', '') <> coalesce(p_exchange->>'internal_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@refObjectId', '') <> coalesce(p_exchange->>'flow_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@version', '') <> coalesce(p_exchange->>'flow_version', '')
    or coalesce(v_entry->>'exchangeDirection', '') <> coalesce(p_exchange->>'direction', '')
    or v_entry->>'meanAmount' is distinct from p_exchange->>'before_amount'
    or v_entry->>'resultingAmount' is distinct from coalesce(p_exchange->>'before_resulting_amount', p_exchange->>'before_amount') then
    return null;
  end if;
  v_after_mean := private.dataset_alias_v2_multiply_amount(p_exchange->>'before_amount', private.dataset_alias_v2_factor()::text);
  v_after_resulting := private.dataset_alias_v2_multiply_amount(
    coalesce(p_exchange->>'before_resulting_amount', p_exchange->>'before_amount'),
    private.dataset_alias_v2_factor()::text);
  if v_after_mean is null or v_after_mean is distinct from p_exchange->>'after_amount'
    or v_after_resulting is null
    or v_after_resulting is distinct from coalesce(p_exchange->>'after_resulting_amount', p_exchange->>'after_amount') then
    return null;
  end if;
  return jsonb_set(
    jsonb_set(p_before, array['processDataSet', 'exchanges', 'exchange', v_index::text, 'meanAmount'], to_jsonb(v_after_mean), false),
    array['processDataSet', 'exchanges', 'exchange', v_index::text, 'resultingAmount'], to_jsonb(v_after_resulting), false);
end
$$;

ALTER FUNCTION "private"."dataset_alias_v2_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") FROM PUBLIC;
