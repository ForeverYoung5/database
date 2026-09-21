CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_fu_path_ok"("p_path" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select p_path = 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text'
$$;

ALTER FUNCTION "private"."dataset_alias_v2_fu_path_ok"("p_path" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_fu_path_ok"("p_path" "text") FROM PUBLIC;
