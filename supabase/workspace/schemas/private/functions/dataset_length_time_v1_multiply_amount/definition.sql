CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_multiply_amount"("p_amount" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_output text;
begin
  if not private.dataset_alias_v2_amount_grammar_ok(p_amount) then
    return null;
  end if;
  v_output := private.dataset_alias_v2_render_amount(p_amount::numeric * private.dataset_length_time_v1_factor());
  if v_output is null or octet_length(v_output) > 128 then
    return null;
  end if;
  return v_output;
exception
  when numeric_value_out_of_range then
    return null;
end
$$;

ALTER FUNCTION "private"."dataset_length_time_v1_multiply_amount"("p_amount" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_multiply_amount"("p_amount" "text") FROM PUBLIC;
