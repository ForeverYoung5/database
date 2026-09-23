CREATE OR REPLACE FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean DEFAULT false) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select lower(coalesce(p_data_source, '')) = 'sl'
    and auth.uid() is not null
    and private.lca_release_is_manager()
    and p_state_code = 100
    and (
      coalesce(p_filter->>'__sampleLibraryOrigin', 'all') = 'all'
      or (p_filter->>'__sampleLibraryOrigin' = 'literature' and p_user_id is null)
      or (p_filter->>'__sampleLibraryOrigin' = 'enterprise' and p_user_id is not null)
    )
    and (
      not p_is_process
      or coalesce(p_filter->>'__sampleLibraryPublicationStatus', 'all') = 'all'
      or (
        p_filter->>'__sampleLibraryPublicationStatus' = 'published'
        and exists (
          select 1
          from private.sample_library_process_publications publication
          where publication.process_id = p_id
            and publication.process_version = p_version
        )
      )
      or (
        p_filter->>'__sampleLibraryPublicationStatus' = 'unpublished'
        and not exists (
          select 1
          from private.sample_library_process_publications publication
          where publication.process_id = p_id
            and publication.process_version = p_version
        )
      )
    );
$$;

ALTER FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean) TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean) TO "anon";

GRANT ALL ON FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean) TO "authenticated";

GRANT ALL ON FUNCTION "api"."sample_library_row_matches_v1"("p_data_source" "text", "p_state_code" integer, "p_user_id" "uuid", "p_id" "uuid", "p_version" character, "p_filter" "jsonb", "p_is_process" boolean) TO "service_role";
