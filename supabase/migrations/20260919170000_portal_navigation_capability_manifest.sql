-- Database #656: register the navigation and V3 facades in the capability manifest.
--
-- Every browser-reachable `api.*` routine must appear in the manifest-backed
-- PostgREST pre-request hook, otherwise the route fails closed. The new
-- navigation and V3 facades therefore get the same Portal capability classes as
-- the v1/v2 catalog facades they extend, and nothing else changes.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $portal_navigation_capability_guard$
begin
  if not exists (
    select 1
    from private.api_capability_grants
    where routine_identity = 'api.portal_search_processes_v2(text, jsonb, text, text, integer)'
      and capability_id = 'PORTAL-CATALOG-01'
  ) then
    raise exception 'Portal catalog capability class is absent'
      using errcode = '55000';
  end if;
end;
$portal_navigation_capability_guard$;

insert into private.api_capability_grants(
  routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role
) values
  ('api.portal_navigation_v1(text, text, jsonb, text, text, text, integer)',
    'PORTAL-CATALOG-01', true, true, false),
  ('api.portal_search_processes_v3(text, jsonb, text, text, integer)',
    'PORTAL-CATALOG-01', true, true, false),
  ('api.portal_search_flows_v3(text, jsonb, text, text, integer)',
    'PORTAL-CATALOG-01', true, true, false),
  ('api.portal_facets_v3(text, text, jsonb)',
    'PORTAL-CATALOG-01', true, true, false)
on conflict (routine_identity) do update
set capability_id = excluded.capability_id,
    allow_anon = excluded.allow_anon,
    allow_authenticated = excluded.allow_authenticated,
    allow_service_role = excluded.allow_service_role;

notify pgrst, 'reload schema';

commit;
