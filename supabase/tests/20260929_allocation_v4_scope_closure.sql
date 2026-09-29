begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;

select plan(8);

-- Keep entity-trigger dispatch inside this rolled-back database test.
create or replace function util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  null;
end;
$$;

insert into public.processes(
  id, version, state_code, json, json_ordered, user_id
) values (
  'c8010000-0000-4000-8000-000000000010',
  '01.00.000',
  100,
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c8010000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c8010000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  null
)
on conflict (id, version) do update
set state_code = excluded.state_code,
    json = excluded.json,
    json_ordered = excluded.json_ordered;

insert into public.lciamethods(
  id, version, state_code, json, json_ordered, user_id
) values (
  '9ec743ea-6b00-400d-a53b-61547a3fc03c',
  '01.01.000',
  0,
  '{"LCIAMethodDataSet":{"LCIAMethodInformation":{"dataSetInformation":{"common:UUID":"503699e0-eca9-4089-8bf8-e0f49c93e578"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.01.000"}}}}',
  '{"LCIAMethodDataSet":{"LCIAMethodInformation":{"dataSetInformation":{"common:UUID":"503699e0-eca9-4089-8bf8-e0f49c93e578"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.01.000"}}}}',
  null
)
on conflict (id, version) do update
set state_code = excluded.state_code,
    json = excluded.json,
    json_ordered = excluded.json_ordered;

create temporary table allocation_scope_request on commit drop as
select '{"coverageMode":"subset","processes":[{"id":"c8010000-0000-4000-8000-000000000010","version":"01.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb as request;
create temporary table allocation_scope_manifest on commit drop as
select private.lcia_scope_closure_normalize_request(request) as manifest from allocation_scope_request;

select is((select manifest #>> '{linkPolicy,allocationSemanticsVersion}' from allocation_scope_manifest),
  'tidas-reference-allocation-v4', 'omitted allocation semantics freeze v4');
select is((select private.lcia_scope_closure_normalize_request(request || '{"linkPolicy":{"allocationSemanticsVersion":"tidas-reference-allocation-v4"}}'::jsonb) from allocation_scope_request),
  (select manifest from allocation_scope_manifest), 'explicit v4 and omitted policy have identical canonical manifests');
select is((select private.lcia_scope_closure_sha256(private.lcia_scope_closure_normalize_request(request)) from allocation_scope_request),
  (select private.lcia_scope_closure_sha256(manifest) from allocation_scope_manifest), 'identical v4 requests have stable replay identity');
select isnt((select private.lcia_scope_closure_sha256(manifest) from allocation_scope_manifest),
  (select private.lcia_scope_closure_sha256(jsonb_set(manifest, '{linkPolicy,allocationSemanticsVersion}', '"tidas-reference-allocation-v3"'::jsonb)) from allocation_scope_manifest),
  'historical v3 manifest cannot share the v4 hash');
select throws_ok($sql$select private.lcia_scope_closure_normalize_request(request || '{"linkPolicy":{"allocationSemanticsVersion":"tidas-reference-allocation-v3"}}'::jsonb) from allocation_scope_request$sql$,
  '22023', 'invalid_closure_link_policy', 'explicit stale v3 intent is rejected rather than relabeled');
select throws_ok($sql$select private.lcia_scope_closure_normalize_request(request || '{"linkPolicy":{"allocationSemanticsVersion":"tidas-reference-allocation-v5"}}'::jsonb) from allocation_scope_request$sql$,
  '22023', 'invalid_closure_link_policy', 'unknown future semantics are rejected');
select is((select manifest #>> '{linkPolicy,technosphereBoundaryPolicy}' from allocation_scope_manifest),
  'cutoff', 'allocation upgrade preserves the certificate cutoff boundary');
select ok(not has_function_privilege('authenticated', 'private.lcia_scope_closure_normalize_request(jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'private.lcia_scope_closure_normalize_request(jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'private.lcia_scope_closure_normalize_request(jsonb)', 'EXECUTE'),
  'normalizer stays internal with its service-only execution boundary');
select * from finish();
rollback;
