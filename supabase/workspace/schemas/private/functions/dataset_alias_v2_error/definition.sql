CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_error"("p_code" "text", "p_status" integer, "p_message" "text", "p_details" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select jsonb_build_object('code', p_code, 'status', p_status, 'message', p_message,
    'details', coalesce(p_details, '{}'::jsonb))::text
$$;

ALTER FUNCTION "private"."dataset_alias_v2_error"("p_code" "text", "p_status" integer, "p_message" "text", "p_details" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_error"("p_code" "text", "p_status" integer, "p_message" "text", "p_details" "jsonb") FROM PUBLIC;
