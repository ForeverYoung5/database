-- Database #738: closed server-log diagnostics; public errors and read semantics stay unchanged.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
-- Execute replacement as the existing owner. Preserve temporary DDL grant
-- prestate, including membership options and the existing schema privilege.
do $portal_diag_acl_begin$
declare r text; before_grant jsonb;
begin
  foreach r in array array['api_internal_executor','portal_public_executor'] loop
    select pg_catalog.jsonb_build_object('admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)
      into before_grant from pg_catalog.pg_auth_members m
      where m.roleid=r::regrole and m.member='postgres'::regrole and m.grantor=current_user::regrole;
    perform pg_catalog.set_config('portal_read_diagnostics.'||r||'_postgres_grant',coalesce(before_grant,'null'::jsonb)::text,true);
    execute pg_catalog.format('grant %I to postgres',r);
  end loop;
  perform pg_catalog.set_config('portal_read_diagnostics.create_added',
    (not pg_catalog.has_schema_privilege('portal_public_executor','api','CREATE'))::text,true);
  if pg_catalog.current_setting('portal_read_diagnostics.create_added')::boolean then
    grant create on schema api to portal_public_executor;
  end if;
end;
$portal_diag_acl_begin$;
set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
begin
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_version is null
     or p_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  return private.portal_lcia_decorate_dataset_v1(
    private.portal_dataset_projection_v1(p_kind, p_id, p_version)
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "api"."portal_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "api"."portal_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") TO "anon";

GRANT ALL ON FUNCTION "api"."portal_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") TO "authenticated";

reset role;
do $portal_diag_acl_end$
declare r text; before_grant jsonb;
begin
  if pg_catalog.current_setting('portal_read_diagnostics.create_added')::boolean then
    revoke create on schema api from portal_public_executor;
  end if;
  foreach r in array array['portal_public_executor','api_internal_executor'] loop
    before_grant:=pg_catalog.current_setting('portal_read_diagnostics.'||r||'_postgres_grant')::jsonb;
    if before_grant='null'::jsonb then
      execute pg_catalog.format('revoke %I from postgres',r);
    else
      execute pg_catalog.format('grant %I to postgres with admin %s, inherit %s, set %s',
        r,before_grant->>'admin',before_grant->>'inherit',before_grant->>'set');
    end if;
  end loop;
end;
$portal_diag_acl_end$;
commit;
