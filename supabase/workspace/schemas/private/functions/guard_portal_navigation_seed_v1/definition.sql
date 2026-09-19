CREATE OR REPLACE FUNCTION "private"."guard_portal_navigation_seed_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if old.source_file is not null or old.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped') then
    raise exception 'Seeded navigation vocabulary is immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

ALTER FUNCTION "private"."guard_portal_navigation_seed_v1"() OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."guard_portal_navigation_seed_v1"() FROM PUBLIC;
