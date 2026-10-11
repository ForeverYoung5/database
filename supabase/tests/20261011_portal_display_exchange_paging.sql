-- Rollback-only synthetic World steel-size exchanges, real scoped API and RLS.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
create or replace function util.invoke_edge_function(name text,body jsonb,timeout_milliseconds integer default 300000)
returns void language plpgsql security definer set search_path='' as $$begin return; end$$;

-- Fixture uses visible cross-brand/null support with no license metadata.
insert into public.unitgroups(id,version,state_code,json) values
('82100000-0000-4000-8000-000000000001','01.00.000',0,'{"unitGroupDataSet":{"unitGroupInformation":{"quantitativeReference":{"referenceToReferenceUnit":"0"}},"units":{"unit":{"@dataSetInternalID":"0","name":"kg","meanValue":"1"}}}}');
insert into public.flowproperties(id,version,state_code,json) values
('82100000-0000-4000-8000-000000000002','01.00.000',20,'{"flowPropertyDataSet":{"flowPropertiesInformation":{"quantitativeReference":{"referenceToReferenceUnitGroup":{"@type":"unit group data set","@refObjectId":"82100000-0000-4000-8000-000000000001","@version":"01.00.000"}}}}}');
insert into public.flows(id,version,state_code,json)
select ('82100000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.000',0,
jsonb_build_object('flowDataSet',jsonb_build_object(
 'flowInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName','Synthetic flow '||i)),
 'quantitativeReference',jsonb_build_object('referenceToReferenceFlowProperty','0')),
 'flowProperties',jsonb_build_object('flowProperty',jsonb_build_object('@dataSetInternalID','0','meanValue','1','referenceToFlowPropertyDataSet',jsonb_build_object('@type','flow property data set','@refObjectId','82100000-0000-4000-8000-000000000002','@version','01.00.000'))),
 'modellingAndValidation',jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet',case i when 3 then 'Product flow' when 4 then 'Elementary flow' else 'Waste flow' end))))
from generate_series(3,5) i;
create function pg_temp.exchange_item(internal_id text,flow_number integer default 3) returns jsonb
language sql immutable as $$select jsonb_build_object('@dataSetInternalID',internal_id,'exchangeDirection','Output','meanAmount','0.12345678901234567890123456789','referenceToFlowDataSet',jsonb_build_object('@type','flow data set','@refObjectId','82100000-0000-4000-8000-'||lpad(flow_number::text,12,'0'),'@version','01.00.000'))$$;
insert into public.processes(id,version,state_code,json)
select ('82100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'01.00.000',0,
jsonb_build_object('processDataSet',jsonb_build_object('processInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName','Synthetic World steel '||n)),
'quantitativeReference',jsonb_build_object('referenceToReferenceFlow','1')),'exchanges',jsonb_build_object('exchange',(select jsonb_agg(pg_temp.exchange_item(i::text) order by i desc) from generate_series(1,n) i))))
from (values (2540),(2556)) sizes(n);
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand)
select 'process',id,version,true,'worldsteel' from public.processes where id::text like '82100000%'
union all select 'flow',id,version,true,'bafu' from public.flows where id::text like '82100000%'
union all select 'flowproperty',id,version,true,'uslci' from public.flowproperties where id::text like '82100000%'
union all select 'unitgroup',id,version,true,null from public.unitgroups where id::text like '82100000%';
update private.portal_display_rollout set mode='display';
-- End fixture. The rollback-only predecessor comparison harness reuses this block.

create temp table exchange_pages(page jsonb);
grant select,insert,delete on exchange_pages to anon;
set local role anon;
insert into exchange_pages select api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','all',null,20);
select is((select jsonb_array_length(page->'rows') from exchange_pages),20,'2540 exchanges: first page has 20 supported rows');
select is((select page#>>'{rows,0,internalId}' from exchange_pages),'1','numeric ordering ignores reversed source order');
select is((select page#>>'{rows,19,internalId}' from exchange_pages),'20','first page ends at 20');
select is((select page#>>'{rows,0,amount}' from exchange_pages),'0.12345678901234567890123456789','decimal text precision retained');
select is((select page#>>'{processContext,functionalUnit,unit}' from exchange_pages),'kg','cross-brand/null support resolves the functional unit');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','all',(select page->>'nextCursor' from exchange_pages),20)#>>'{rows,0,internalId}','21','page two starts after cursor');
select is(api.portal_list_process_exchanges_v2(array['tiangong_lca'],'82100000-0000-4000-8000-000000002540','01.00.000'),null::jsonb,'out-of-brand root stays unavailable');
select throws_ok($q$select api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','all','invalid',20)$q$,'22023','invalid portal request','invalid cursor rejected');
select throws_ok(format('select api.portal_list_process_exchanges_v2(array[''worldsteel''],''82100000-0000-4000-8000-000000002540'',''01.00.000'',''waste'',%L,20)',(select page->>'nextCursor' from exchange_pages)),'22023','invalid portal request','cursor kind binding retained');
reset role;

-- Count support calls, including functional-unit validation. Instrument only in
-- this transaction and restore the exact original definition before rollback.
create temp table saved_support as select pg_get_functiondef('private.display_exchange_support_v1(integer,jsonb,jsonb)'::regprocedure) definition;
create temporary sequence support_calls;
grant usage,select on sequence support_calls to portal_display_executor;
do $$begin execute replace((select definition from saved_support),E'begin\n',E'begin\n  perform nextval(''pg_temp.support_calls'');\n'); end$$;
update private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1();
set local role anon;
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002556','01.00.000','all',null,20)->'rows'),20,'2556 exchanges: instrumented public page still correct');
reset role;
select is((select last_value from support_calls),22::bigint,'only functional unit plus 20 page rows and one lookahead are hydrated');
do $$begin execute (select definition from saved_support); end$$;
update private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1();

-- Sparse valid rows, a duplicate straddling the page frontier, malformed IDs,
-- invalid decimals/exact versions and normalized-ID aliases of different kinds.
update public.processes set json=jsonb_set(json,'{processDataSet,exchanges,exchange}',
 jsonb_build_array(pg_temp.exchange_item('1'),pg_temp.exchange_item('2'),pg_temp.exchange_item('3',4),
 pg_temp.exchange_item('4',5),pg_temp.exchange_item('5')||'{"meanAmount":"NaN"}',
 pg_temp.exchange_item('6')||'{"referenceToFlowDataSet":{"@type":"flow data set","@refObjectId":"82100000-0000-4000-8000-000000000003","@version":"99.99.999"}}',
 pg_temp.exchange_item('bad'),pg_temp.exchange_item('99999999999999999'),pg_temp.exchange_item('7',4),
 pg_temp.exchange_item(' 7 ',3),pg_temp.exchange_item('  7 ',5),pg_temp.exchange_item('8'),pg_temp.exchange_item('2')||'{"meanAmount":"bad"}'))
where id='82100000-0000-4000-8000-000000002540';
delete from exchange_pages;
set local role anon;
insert into exchange_pages select api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','all',null,4);
select is((select jsonb_path_query_array(page,'$.rows[*].internalId') from exchange_pages),'["1","3","4","7"]'::jsonb,'all-array duplicate detection and invalid support precede page filling');
select is((select page#>>'{rows,3,kind}' from exchange_pages),'elementary','normalized-ID alias group orders by kind');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','all',(select page->>'nextCursor' from exchange_pages),4)#>'{rows,0,kind}','"technosphere"'::jsonb,'same numeric ID with later kind continues correctly');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','all',(select page->>'nextCursor' from exchange_pages),4)->'nextCursor','null'::jsonb,'final partial page has no false continuation');
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000','waste',null,1)->'rows'),1,'kind filter fills a page after skipped kinds');
reset role;
update private.dataset_display_settings set is_visible=false where dataset_kind='unitgroup' and dataset_id='82100000-0000-4000-8000-000000000001';
set local role anon;
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82100000-0000-4000-8000-000000002540','01.00.000')->'rows'),0,'hidden exact support still blocks numerics');
reset role;
select lives_ok($q$select private.portal_display_assert_contract_v1()$q$,'original helper and manifest restored');
select * from finish();
rollback;
