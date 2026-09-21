CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_replace_fu_text"("p_before" "jsonb", "p_functional_unit" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_path text := coalesce(p_functional_unit->>'path', '');
  v_before_text text := p_functional_unit->>'before_text';
  v_after_text text := p_functional_unit->>'after_text';
  v_stored text := p_before #>> string_to_array(v_path, '.');
  v_derived text;
begin
  if not private.dataset_alias_v2_fu_path_ok(v_path) or v_before_text is null or v_after_text is null then
    return null;
  end if;
  if v_stored is distinct from v_before_text then
    return null;
  end if;
  v_derived := private.dataset_alias_v2_fu_apply_rule(v_before_text);
  if v_derived is null or v_derived is distinct from v_after_text then
    return null;
  end if;
  return jsonb_set(p_before, string_to_array(v_path, '.'), to_jsonb(v_derived), false);
end
$$;

ALTER FUNCTION "private"."dataset_alias_v2_replace_fu_text"("p_before" "jsonb", "p_functional_unit" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_replace_fu_text"("p_before" "jsonb", "p_functional_unit" "jsonb") FROM PUBLIC;
