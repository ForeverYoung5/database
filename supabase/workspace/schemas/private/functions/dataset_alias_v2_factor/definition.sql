CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_factor"() RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select 0.00011415525114155251::numeric
$$;

ALTER FUNCTION "private"."dataset_alias_v2_factor"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_factor"() FROM PUBLIC;
