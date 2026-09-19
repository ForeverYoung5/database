-- Rollback-only proof on the isolated local Database #656 stack.
--
-- Covers the versioned navigation RPC, its closure projection and alias
-- resolution, the V3 node filters and the bounded catalog summary. Fixtures are
-- synthetic, every assertion runs inside one transaction, and the transaction is
-- rolled back at the end.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions,public,auth;
select extensions.no_plan();

grant portal_public_executor to postgres;
set role portal_public_executor;

create temp table nav_card_a as
select private.portal_catalog_card_v1('process', 100, jsonb_build_object('processDataSet', jsonb_build_object('processInformation', jsonb_build_object('dataSetInformation', jsonb_build_object('name', jsonb_build_object('baseName', jsonb_build_array(jsonb_build_object('@xml:lang','en','#text','NavAlpha'))),'classificationInformation', jsonb_build_object('common:classification', jsonb_build_array(jsonb_build_object('@name','ISIC','common:class', jsonb_build_array(jsonb_build_object('@level','0','@classId','A','#text','Agriculture, forestry and fishing'), jsonb_build_object('@level','1','@classId','01','#text','Crop and animal production')))))),'time', jsonb_build_object('common:referenceYear','2024'),'geography', jsonb_build_object('locationOfOperationSupplyOrProduction',jsonb_build_object('@location','SD-CN'))),'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))) as payload;

create temp table nav_card_b as
select private.portal_catalog_card_v1('process', 100, jsonb_build_object('processDataSet', jsonb_build_object('processInformation', jsonb_build_object('dataSetInformation', jsonb_build_object('name', jsonb_build_object('baseName', jsonb_build_array(jsonb_build_object('@xml:lang','en','#text','NavBeta'))),'classificationInformation', jsonb_build_object('common:classification', jsonb_build_array(jsonb_build_object('@name','ISIC','common:class', jsonb_build_array(jsonb_build_object('@level','0','@classId','C','#text','Manufacturing'), jsonb_build_object('@level','1','@classId','10','#text','Food products')))))),'time', jsonb_build_object('common:referenceYear','2024'),'geography', jsonb_build_object('locationOfOperationSupplyOrProduction',jsonb_build_object('@location','SD-CN'))),'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))) as payload;

create temp table nav_card_c as
select private.portal_catalog_card_v1('process', 100, jsonb_build_object('processDataSet', jsonb_build_object('processInformation', jsonb_build_object('dataSetInformation', jsonb_build_object('name', jsonb_build_object('baseName', jsonb_build_array(jsonb_build_object('@xml:lang','en','#text','NavGamma'))),'classificationInformation', jsonb_build_object('common:classification', jsonb_build_array(jsonb_build_object('@name','ISIC','common:class', jsonb_build_array(jsonb_build_object('@level','0','@classId','A','#text','Agriculture, forestry and fishing')))))),'time', jsonb_build_object('common:referenceYear','2024'),'geography', jsonb_build_object('locationOfOperationSupplyOrProduction',jsonb_build_object('@location','AQ-AH-CN'))),'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))) as payload;

create temp table nav_card_d as
select private.portal_catalog_card_v1('process', 100, jsonb_build_object('processDataSet', jsonb_build_object('processInformation', jsonb_build_object('dataSetInformation', jsonb_build_object('name', jsonb_build_object('baseName', jsonb_build_array(jsonb_build_object('@xml:lang','en','#text','NavDelta'))),'classificationInformation', jsonb_build_object('common:classification', jsonb_build_array(jsonb_build_object('@name','ISIC','common:class', jsonb_build_array())))),'time', jsonb_build_object('common:referenceYear','2024'),'geography', jsonb_build_object('locationOfOperationSupplyOrProduction',jsonb_build_object('@location','ZZ-XX'))),'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))) as payload;

create temp table nav_card_e as
select private.portal_catalog_card_v1('flow', 100, jsonb_build_object('flowDataSet', jsonb_build_object('flowInformation', jsonb_build_object('dataSetInformation', jsonb_build_object('name', jsonb_build_object('baseName', jsonb_build_array(jsonb_build_object('@xml:lang','en','#text','NavEpsilon'))),'classificationInformation', jsonb_build_object('common:classification', jsonb_build_array(jsonb_build_object('@name','CPC','common:class', jsonb_build_array(jsonb_build_object('@level','0','@classId','0','#text','Agriculture, forestry and fishery products'))))),'CASNumber','50-00-0'),'geography', jsonb_build_object('locationOfSupply',jsonb_build_object('@location','US'))),'modellingAndValidation', jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet','Elementary flow')),'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))) as payload;

reset role;

begin;

-- Idempotent: a previous interrupted run may have committed its fixtures.
delete from private.portal_navigation_membership_v1
where dimension = 'classification' or dimension = 'geography';
delete from private.portal_catalog_search_rows_v2
where id::text like '90000000-0000-4000-8000-%';
delete from private.portal_catalog_search_rows_v1
where id::text like '90000000-0000-4000-9000-%';

insert into private.portal_catalog_search_rows_v2
  (dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version)
select 'process', '90000000-0000-4000-8000-00000000000a'::uuid, '01.01.000', 100, now(), payload, payload ->> 'document', 2
from nav_card_a;

select private.sync_portal_navigation_membership_v1(
  'process', '90000000-0000-4000-8000-00000000000a'::uuid, '01.01.000', (select payload from nav_card_a limit 1));


insert into private.portal_catalog_search_rows_v2
  (dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version)
select 'process', '90000000-0000-4000-8000-00000000000b'::uuid, '01.01.000', 100, now(), payload, payload ->> 'document', 2
from nav_card_b;

select private.sync_portal_navigation_membership_v1(
  'process', '90000000-0000-4000-8000-00000000000b'::uuid, '01.01.000', (select payload from nav_card_b limit 1));


insert into private.portal_catalog_search_rows_v2
  (dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version)
select 'process', '90000000-0000-4000-8000-00000000000c'::uuid, '01.01.000', 100, now(), payload, payload ->> 'document', 2
from nav_card_c;

select private.sync_portal_navigation_membership_v1(
  'process', '90000000-0000-4000-8000-00000000000c'::uuid, '01.01.000', (select payload from nav_card_c limit 1));


insert into private.portal_catalog_search_rows_v2
  (dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version)
select 'process', '90000000-0000-4000-8000-00000000000d'::uuid, '01.01.000', 100, now(), payload, payload ->> 'document', 2
from nav_card_d;

select private.sync_portal_navigation_membership_v1(
  'process', '90000000-0000-4000-8000-00000000000d'::uuid, '01.01.000', (select payload from nav_card_d limit 1));


insert into private.portal_catalog_search_rows_v1
  (dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version)
select 'flow', '90000000-0000-4000-9000-00000000000e'::uuid, '01.01.000', 100, now(), payload, payload ->> 'document', 1
from nav_card_e;

select private.sync_portal_navigation_membership_v1(
  'flow', '90000000-0000-4000-9000-00000000000e'::uuid, '01.01.000', (select payload from nav_card_e limit 1));


commit;

-- ---------------------------------------------------------------------------
-- Closure and alias resolution.
-- ---------------------------------------------------------------------------
select extensions.is(
  (select count(*)::integer from private.portal_navigation_membership_v1),
  21,
  'Every authored placement contributes exactly its own closure chain');

select extensions.is(
  (select count(*)::integer
   from private.portal_navigation_membership_v1 as member
   where member.node_id = 'class:isic' and member.dataset_kind = 'process'
     and member.direct),
  0,
  'An ancestor closure row is never marked direct');

select extensions.ok(
  (select pg_catalog.bool_and(member.direct)
   from private.portal_navigation_membership_v1 as member
   where member.node_id in ('class:isic:2.0', 'class:isic:0.0')
     and member.dataset_kind = 'process'),
  'Only the authored placement of each branch is direct');

select extensions.is(
  (select pg_catalog.count(*)::integer
   from private.portal_navigation_membership_v1 as member
   where member.node_id = 'geo:cn-sd' and member.dataset_kind = 'process'
     and not member.direct),
  0,
  'The authored province is direct while its country ancestor is not');

select extensions.ok(
  (select exists (
     select 1 from private.portal_navigation_membership_v1 as member
     where member.node_id = 'geo:cn-sd' and member.direct)
   and exists (
     select 1 from private.portal_navigation_membership_v1 as member
     where member.node_id = 'geo:cn-ah-aqg' and member.direct)),
  'The archive city code resolves to the canonical prefecture');

select extensions.is(
  (select pg_catalog.count(distinct member.node_id)::integer
   from private.portal_navigation_membership_v1 as member
   where member.node_id in ('geo:cn', 'geo:cn-sd', 'geo:cn-ah', 'geo:cn-ah-aqg')),
  4,
  'The closure reaches the country through every intermediate level');

select extensions.ok(
  (select exists (
     select 1 from private.portal_navigation_membership_v1 as member
     where member.node_id = 'class:unclassified' and member.direct)),
  'A version with no usable classification lands in the explicit bucket');

-- ---------------------------------------------------------------------------
-- Navigation page shape, counts and totals.
-- ---------------------------------------------------------------------------
grant portal_public_executor to postgres;
set role portal_public_executor;

select extensions.is(
  (select api.portal_navigation_v1('process', '', '{}'::jsonb, 'classification', null, null, 100)
     #>> '{countBasis}'),
  'public_versions',
  'The navigation page states its count basis');

select extensions.is(
  (select api.portal_navigation_v1('process', '', '{}'::jsonb, 'classification', null, null, 100)
     #>> '{totals,process}'),
  '4',
  'A process page reports the process total');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic', null, 100)
     #>> '{totals,flow}'),
  '1',
  'Totals keep measuring the other kind instead of reporting zero');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic', null, 100)
     #>> '{parent,nodeId}'),
  'class:isic',
  'The parent is the requested branch node');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic', null, 100)
     #>> '{parent,count}'),
  '3',
  'The parent carries its own subtree count');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic', null, 100)
     #>> '{parent,directCount}'),
  '0',
  'The parent carries its own direct count');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic:0', null, 100)
     #>> '{nodes,0,count}'),
  '1',
  'A branch node counts its own subtree');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic:0', null, 100)
     #>> '{nodes,0,directCount}'),
  '1',
  'A branch node counts only its direct members separately');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic:0.0', null, 100)
     #>> '{nodes,0,directCount}'),
  '0',
  'A leaf with no children of its own reports no nested members');

select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic:0.0', null, 100)
     -> 'ancestors')),
  2,
  'Ancestors are root-first and exclude the parent');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic:0.0', null, 100)
     #>> '{ancestors,0,nodeId}'),
  'class:isic',
  'Ancestors start at the taxonomy root');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', 'class:isic:0.0', null, 100)
     #>> '{ancestors,0,nodeId}'),
  'class:isic',
  'The first ancestor is the taxonomy root');

select extensions.is(
  (select api.portal_navigation_v1(
       'flow', '', '{}'::jsonb, 'geography', 'geo:us', null, 100)
     #>> '{totals,flow}'),
  '1',
  'A flow page reports the flow total from the flow projection');

select extensions.is(
  (select api.portal_navigation_v1(
       'all', '', '{}'::jsonb, 'geography', 'geo:cn', null, 100)
     #>> '{parent,count}'),
  '3',
  'A geography branch counts every Chinese fixture, including the unplaced one');

-- ---------------------------------------------------------------------------
-- V3 node filters.
-- ---------------------------------------------------------------------------
select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_search_processes_v3('', '{"classificationNodeId":"class:isic:0.0"}'::jsonb)
     -> 'items')),
  1,
  'A V3 classification node filter reaches the pre-filter');

select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_search_processes_v3('', '{"classificationNodeId":"class:isic:0"}'::jsonb)
     -> 'items')),
  2,
  'A V3 subtree scope matches the whole branch');

select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_search_processes_v3(
       '', '{"classificationNodeId":"class:isic:0","classificationScope":"direct"}'::jsonb)
     -> 'items')),
  1,
  'A V3 direct scope excludes versions that authored only a descendant');

select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_search_processes_v3('', '{"geographyNodeId":"geo:cn-sd"}'::jsonb)
     -> 'items')),
  2,
  'A V3 geography node filter resolves the archive spelling through the alias');

select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_facets_v3('process', '', '{"classificationNodeId":"class:isic:0"}'::jsonb)
     -> 'groups')),
  6,
  'V3 facets accept the same node filter and keep the facet group inventory');

-- ---------------------------------------------------------------------------
-- Cursor, page bounds and refusal behaviour.
-- ---------------------------------------------------------------------------
select extensions.ok(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', null, null, 2)
     #>> '{nextCursor}' is not null),
  'A bounded page exposes a keyset cursor while siblings remain');

select extensions.is(
  (select pg_catalog.jsonb_array_length(
     api.portal_navigation_v1('process', '', '{}'::jsonb, 'classification', null, null, 2)
     -> 'nodes')),
  2,
  'A bounded page returns exactly the requested number of nodes');

select extensions.is(
  (select api.portal_navigation_v1(
       'process', '', '{}'::jsonb, 'classification', null, null, 2)
     #>> '{nodes,0,nodeId}'),
  'class:cpc',
  'The root page is ordered by node id');

select extensions.throws_ok(
  $sql$select api.portal_navigation_v1('process', '', '{}'::jsonb, 'classification', 'geo:cn-sd', null, 5)$sql$,
  '22023',
  'invalid portal request',
  'A node from the other dimension is rejected');

select extensions.throws_ok(
  $sql$select api.portal_search_processes_v3('', '{"classificationScope":"direct"}'::jsonb)$sql$,
  '22023',
  'invalid portal request',
  'A V3 scope without its node is rejected');

select extensions.throws_ok(
  $sql$select api.portal_search_processes_v3('', '{"classificationNodeId":"class:nope"}'::jsonb)$sql$,
  '22023',
  'invalid portal request',
  'A V3 node outside the vocabulary is rejected');

reset role;
revoke portal_public_executor from postgres;

-- ---------------------------------------------------------------------------
-- The summary facade keeps its published shape and its statement budget.
-- ---------------------------------------------------------------------------
grant portal_public_executor to postgres;
set role portal_public_executor;
select extensions.is(
  (select api.portal_catalog_summary_v1() ->> 'schemaVersion'),
  'portal.public-catalog-summary.v1',
  'The catalog summary keeps its published schema version');
reset role;
revoke portal_public_executor from postgres;

select extensions.ok(
  (select p.prosrc !~ 'portal_catalog_search_current_v2'
      and p.prosrc ~ 'portal_catalog_search_rows_v2'
      and p.prosrc ~ 'portal_catalog_search_rows_v1'
      and p.proconfig @> array[
        'statement_timeout=2s', 'jit=off', 'plan_cache_mode=force_custom_plan',
        'max_parallel_workers_per_gather=0', 'work_mem=32MB', 'row_security=on']
    from pg_proc p
    where p.oid = 'api.portal_catalog_summary_v1()'::regprocedure),
  'The summary reads the narrow projection tables and keeps its 2-second budget');

-- ---------------------------------------------------------------------------
-- Anonymous reachability and the untouched v1/v2 surface.
-- ---------------------------------------------------------------------------
select extensions.ok(
  (select has_function_privilege(
     'anon',
     'api.portal_navigation_v1(text,text,jsonb,text,text,text,integer)',
     'execute')),
  'The navigation RPC is reachable anonymously');

select extensions.ok(
  (select not has_function_privilege('anon', 'private.portal_navigation_impl_v1(text,text,jsonb,text,text,text,integer,text)', 'execute')
      and not has_function_privilege('anon', 'private.portal_navigation_node_count_v1(text,text,text,text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'private.sync_portal_navigation_membership_v1(text,uuid,text,jsonb)', 'execute')),
  'The navigation internals stay closed to browser roles');

select extensions.ok(
  (select has_function_privilege('anon', 'api.portal_search_processes_v2(text,jsonb,text,text,integer)', 'execute')
      and has_function_privilege('anon', 'api.portal_search_flows_v2(text,jsonb,text,text,integer)', 'execute')
      and has_function_privilege('anon', 'api.portal_facets_v2(text,text,jsonb)', 'execute')
      and has_function_privilege('anon', 'api.portal_navigation_v1(text,text,jsonb,text,text,text,integer)', 'execute')
      and has_function_privilege('anon', 'api.portal_search_processes_v3(text,jsonb,text,text,integer)', 'execute')),
  'V2 keeps every grant and V3 adds its own');

select extensions.ok(
  (select pg_catalog.count(*) >= 3
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname like 'portal_search_processes_v%'),
  'The v1 and v2 search facades are still present next to v3');

select * from extensions.finish();
rollback;
