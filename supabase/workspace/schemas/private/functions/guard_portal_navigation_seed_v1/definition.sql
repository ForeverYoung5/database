CREATE OR REPLACE FUNCTION "private"."guard_portal_navigation_seed_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  -- Every node identity is immutable, including runtime virtual/raw nodes.
  -- Source writers only INSERT ... ON CONFLICT DO NOTHING.
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'Seeded navigation vocabulary is immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

ALTER FUNCTION "private"."guard_portal_navigation_seed_v1"() OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."guard_portal_navigation_seed_v1"() FROM PUBLIC;
