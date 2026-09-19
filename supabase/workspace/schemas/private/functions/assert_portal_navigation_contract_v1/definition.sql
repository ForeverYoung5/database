CREATE OR REPLACE FUNCTION "private"."assert_portal_navigation_contract_v1"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL SAFE
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
declare
  v_version smallint;
  v_expected integer;
  v_seeded integer;
  v_root text;
begin
  select contract.contract_version,
    contract.node_count
  into v_version, v_expected
  from private.portal_navigation_contract_v1 as contract
  where contract.contract_version = 1;

  if v_version is distinct from 1 then
    raise exception 'Portal navigation contract is absent'
      using errcode = '55000';
  end if;

  -- The check runs inside the seed migration itself, which is the only moment
  -- the vocabulary is exactly the seeded asset. Later migrations add the
  -- projection writer, and from then on a container for an unknown or
  -- unclassified value may be created on demand, so the live total may exceed
  -- the manifest while the seeded rows can never be removed (the membership rows
  -- reference them with ON DELETE RESTRICT).
  select pg_catalog.count(*)::integer
  into v_seeded
  from private.portal_navigation_node_v1 as node;

  if v_seeded < v_expected then
    raise exception 'Portal navigation vocabulary is incomplete'
      using errcode = '55000';
  end if;

  foreach v_root in array array[
    'class:isic', 'class:cpc', 'class:elementary', 'geo:unmapped'
  ]
  loop
    if not exists (
      select 1
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_root
    ) then
      raise exception 'Portal navigation vocabulary root % is absent', v_root
        using errcode = '55000';
    end if;
  end loop;
end;
$$;

ALTER FUNCTION "private"."assert_portal_navigation_contract_v1"() OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."assert_portal_navigation_contract_v1"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."assert_portal_navigation_contract_v1"() TO "postgres";

GRANT ALL ON FUNCTION "private"."assert_portal_navigation_contract_v1"() TO "portal_public_executor";
