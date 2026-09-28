CREATE OR REPLACE FUNCTION "private"."review_rejection_reason_v1"("p_payload" "jsonb") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_comment jsonb;
begin
  if nullif(pg_catalog.btrim(p_payload->>'reason'), '') is not null then
    return pg_catalog.btrim(p_payload->>'reason');
  end if;
  v_comment := p_payload->'comment';
  if pg_catalog.jsonb_typeof(v_comment) = 'object' then
    return nullif(pg_catalog.btrim(v_comment->>'message'), '');
  end if;
  if pg_catalog.jsonb_typeof(v_comment) = 'string' then
    begin
      return nullif(pg_catalog.btrim((v_comment #>> '{}')::jsonb->>'message'), '');
    exception when others then
      return null;
    end;
  end if;
  return null;
end;
$$;

ALTER FUNCTION "private"."review_rejection_reason_v1"("p_payload" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."review_rejection_reason_v1"("p_payload" "jsonb") FROM PUBLIC;
