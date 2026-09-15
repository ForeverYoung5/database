CREATE OR REPLACE FUNCTION "private"."result_process_publish_classify_v1"("p_id" "uuid", "p_version" "text", "p_content_sha256" "text", OUT "classification" "text", OUT "state_code" integer, OUT "stored_sha256" "text") RETURNS "record"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_stored text;
begin
  select process_row.state_code, process_row.json_ordered::text
  into state_code, v_stored
  from public.processes as process_row
  where process_row.id = p_id
    and btrim(process_row.version::text) = p_version;

  if not found then
    classification := 'absent';
    state_code := null;
    stored_sha256 := null;
    return;
  end if;

  stored_sha256 := private.result_process_content_sha256_v1(v_stored);

  if state_code = 120 and stored_sha256 = p_content_sha256 then
    -- Strictly content candidacy. It is not authorization, not actor/source matching, and
    -- not a no-op: execute still resolves the exact receipt before anything else.
    classification := 'candidate_content_matches_existing';
  else
    classification := 'conflict';
  end if;
end;
$$;

ALTER FUNCTION "private"."result_process_publish_classify_v1"("p_id" "uuid", "p_version" "text", "p_content_sha256" "text", OUT "classification" "text", OUT "state_code" integer, OUT "stored_sha256" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_publish_classify_v1"("p_id" "uuid", "p_version" "text", "p_content_sha256" "text", OUT "classification" "text", OUT "state_code" integer, OUT "stored_sha256" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."result_process_publish_classify_v1"("p_id" "uuid", "p_version" "text", "p_content_sha256" "text", OUT "classification" "text", OUT "state_code" integer, OUT "stored_sha256" "text") TO "api_internal_executor";
