CREATE OR REPLACE FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select coalesce(p_filter, '{}'::jsonb)
    - '__sampleLibraryOrigin'
    - '__sampleLibraryPublicationStatus';
$$;

ALTER FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") TO "anon";

GRANT ALL ON FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "private"."sample_library_business_filter_v1"("p_filter" "jsonb") TO "service_role";
