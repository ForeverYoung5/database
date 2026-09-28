CREATE OR REPLACE FUNCTION "private"."comments_sync_submitted_decision_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.state_code = 1 then
    new.submitted_decision := 'approve';
    new.submitted_decision_at := pg_catalog.now();
  elsif new.state_code = -3 then
    new.submitted_decision := 'reject';
    new.submitted_decision_at := pg_catalog.now();
  elsif new.state_code = 0 then
    new.submitted_decision := null;
    new.submitted_decision_at := null;
  elsif tg_op = 'UPDATE' then
    new.submitted_decision := old.submitted_decision;
    new.submitted_decision_at := old.submitted_decision_at;
  end if;
  return new;
end;
$$;

ALTER FUNCTION "private"."comments_sync_submitted_decision_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."comments_sync_submitted_decision_v1"() FROM PUBLIC;
