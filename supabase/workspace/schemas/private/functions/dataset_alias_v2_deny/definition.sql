CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_deny"("p_code" "text", "p_status" integer, "p_message" "text", "p_details" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_code,
    detail = p_message,
    hint = jsonb_build_object('status', p_status, 'details', coalesce(p_details, '{}'::jsonb))::text;
end
$$;

ALTER FUNCTION "private"."dataset_alias_v2_deny"("p_code" "text", "p_status" integer, "p_message" "text", "p_details" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_deny"("p_code" "text", "p_status" integer, "p_message" "text", "p_details" "jsonb") FROM PUBLIC;
