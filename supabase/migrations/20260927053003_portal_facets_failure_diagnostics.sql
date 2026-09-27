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
CREATE OR REPLACE FUNCTION "api"."portal_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v3(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.portal_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v3_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
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
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "api"."portal_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "api"."portal_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") TO "anon";

GRANT ALL ON FUNCTION "api"."portal_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") TO "authenticated";

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
