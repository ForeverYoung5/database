CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_index integer := coalesce((p_exchange->>'index')::integer, -1);
  v_exchanges jsonb := p_before #> '{processDataSet,exchanges,exchange}';
  v_entry jsonb;
  v_after text;
  v_comment text;
  v_label_count integer;
  v_parsed text;
begin
  if v_index < 0 or jsonb_typeof(v_exchanges) <> 'array' or v_index >= jsonb_array_length(v_exchanges) then
    return null;
  end if;
  v_entry := v_exchanges->v_index;
  if jsonb_typeof(v_entry) <> 'object' then
    return null;
  end if;
  -- Absolute-uncertainty fields are outside this profile. The relative field is optional evidence:
  -- the audited corpus carries it on four of thirty-nine selected exchanges and leaves it absent on
  -- the other thirty-five; whatever the row holds — present with its exact value, or absent — is
  -- preserved byte for byte by the rewrite and never invented or reinterpreted.
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
  -- The reviewed source number is bound through the stored source comment, parsed from its anchored
  -- label exactly as the CLI producer does. The deployed corpus carries the comment as an object with
  -- a #text node whose text begins `Source EcoSpold1 exchange number: <N>.` — thirteen end there and
  -- twenty-six continue with source metadata that contains further numbers (years, BU codes, indexed
  -- lists). Those later numbers are never the source id, so the id is taken only from the anchored
  -- label, its bounded numeric token and the mandatory period; every suffix byte is retained in the
  -- payload and never interpreted. A comment with no declaration, with the label spelled without its
  -- token or period, or with anything other than exactly one declaration is refused rather than
  -- guessed, so no metadata number can ever be mistaken for the source id.
  v_comment := case jsonb_typeof(v_entry->'generalComment')
    when 'object' then v_entry->'generalComment'->>'#text'
    when 'string' then v_entry->>'generalComment'
    else null end;
  if v_comment is null then
    return null;
  end if;
  v_label_count := (length(v_comment) - length(replace(v_comment, 'Source EcoSpold1 exchange number:', '')))
    / length('Source EcoSpold1 exchange number:');
  if v_label_count > 1 then
    return null;
  end if;
  if v_label_count <> 1 then
    return null;
  end if;
  v_parsed := substring(v_comment from 'Source EcoSpold1 exchange number:\s*([0-9]+)\.');
  if v_parsed is null or v_parsed is distinct from p_exchange->>'source_exchange_number' then
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
$$;

ALTER FUNCTION "private"."dataset_length_time_v1_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_replace_exchange_amounts"("p_before" "jsonb", "p_exchange" "jsonb") FROM PUBLIC;
