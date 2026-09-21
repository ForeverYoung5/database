CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_render_amount"("p_value" numeric) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when p_value is null then null
    when trim_scale(p_value) = 0 then '0'
    else trim_scale(p_value)::text
  end
$$;

ALTER FUNCTION "private"."dataset_alias_v2_render_amount"("p_value" numeric) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_render_amount"("p_value" numeric) FROM PUBLIC;
