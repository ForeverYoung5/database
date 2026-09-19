CREATE OR REPLACE FUNCTION "private"."sync_portal_navigation_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  if tg_op='DELETE' then
    delete from private.portal_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
    return old;
  end if;
  if tg_op='UPDATE' and (old.dataset_kind,old.id,old.version) is distinct from (new.dataset_kind,new.id,new.version) then
    delete from private.portal_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
  end if;
  perform private.sync_portal_navigation_membership_v1(new.dataset_kind,new.id,new.version,new.card);
  return new;
end;
$$;

ALTER FUNCTION "private"."sync_portal_navigation_row_v1"() OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."sync_portal_navigation_row_v1"() FROM PUBLIC;
