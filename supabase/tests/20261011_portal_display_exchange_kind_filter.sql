-- Rollback-only synthetic World steel-size exchanges, real scoped API and RLS.
begin;
-- Synthetic source writes run real projection triggers; they are not API probes.
set local statement_timeout='60s';
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
create or replace function util.invoke_edge_function(name text,body jsonb,timeout_milliseconds integer default 300000)
returns void language plpgsql security definer set search_path='' as $$begin return; end$$;

-- Fixture uses visible cross-brand/null support with no license metadata.
insert into public.unitgroups(id,version,state_code,json) values
('82400000-0000-4000-8000-000000000001','01.00.000',0,'{"unitGroupDataSet":{"unitGroupInformation":{"quantitativeReference":{"referenceToReferenceUnit":"0"}},"units":{"unit":{"@dataSetInternalID":"0","name":"kg","meanValue":"1"}}}}');
insert into public.flowproperties(id,version,state_code,json) values
('82400000-0000-4000-8000-000000000002','01.00.000',20,'{"flowPropertyDataSet":{"flowPropertiesInformation":{"quantitativeReference":{"referenceToReferenceUnitGroup":{"@type":"unit group data set","@refObjectId":"82400000-0000-4000-8000-000000000001","@version":"01.00.000"}}}}}');
insert into public.flows(id,version,state_code,json)
select ('82400000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.000',0,
jsonb_build_object('flowDataSet',jsonb_build_object(
 'flowInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName','Synthetic flow '||i)),
 'quantitativeReference',jsonb_build_object('referenceToReferenceFlowProperty','0')),
 'flowProperties',jsonb_build_object('flowProperty',jsonb_build_object('@dataSetInternalID','0','meanValue','1','referenceToFlowPropertyDataSet',jsonb_build_object('@type','flow property data set','@refObjectId','82400000-0000-4000-8000-000000000002','@version','01.00.000'))),
 'modellingAndValidation',jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet',case i when 3 then 'Product flow' when 4 then 'Elementary flow' else 'Waste flow' end))))
from generate_series(3,5) i;
create function pg_temp.exchange_item(internal_id text,flow_number integer default 3) returns jsonb
language sql immutable as $$select jsonb_build_object('@dataSetInternalID',internal_id,'exchangeDirection','Output','meanAmount','0.12345678901234567890123456789','referenceToFlowDataSet',jsonb_build_object('@type','flow data set','@refObjectId','82400000-0000-4000-8000-'||lpad(flow_number::text,12,'0'),'@version','01.00.000'))$$;
insert into public.processes(id,version,state_code,json)
select ('82400000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'01.00.000',0,
jsonb_build_object('processDataSet',jsonb_build_object('processInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName','Synthetic World steel '||n)),
'quantitativeReference',jsonb_build_object('referenceToReferenceFlow','1')),'exchanges',jsonb_build_object('exchange',(select jsonb_agg(pg_temp.exchange_item(i::text) order by i desc) from generate_series(1,n) i))))
from (values (2540),(2556)) sizes(n);
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand)
select 'process',id,version,true,'worldsteel' from public.processes where id::text like '82400000%'
union all select 'flow',id,version,true,'bafu' from public.flows where id::text like '82400000%'
union all select 'flowproperty',id,version,true,'uslci' from public.flowproperties where id::text like '82400000%'
union all select 'unitgroup',id,version,true,null from public.unitgroups where id::text like '82400000%';
update private.portal_display_rollout set mode='display';

insert into public.flows(id,version,state_code,json)
select ('82400000-0000-4000-8000-'||lpad((10000+i)::text,12,'0'))::uuid,'01.00.000',0,
jsonb_set(json,'{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}',to_jsonb(case when i=1 or i%61=0 then 'Product flow' when i%67=0 then 'Waste flow' else 'Elementary flow' end))
from public.flows cross join generate_series(1,2556) i
where id='82400000-0000-4000-8000-000000000003';
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand)
select 'flow',id,version,true,'bafu' from public.flows where id::text like '82400000%' and right(id::text,12)::bigint>10000;
update public.processes set json=jsonb_set(json,'{processDataSet,exchanges,exchange}',
(select jsonb_agg(pg_temp.exchange_item(i::text,10000+i) order by i desc) from generate_series(1,right(id::text,12)::integer) i))
where id::text like '82400000%';
-- End fixture. Reused by the rollback-only populated comparison harness.
set local statement_timeout='8s';

create temp table pages(kind text,page jsonb);
grant all on pages to anon;
set local role anon;
insert into pages select kind,api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000',kind,null,20) from unnest(array['technosphere','waste']) kind;
select is((select jsonb_array_length(page->'rows') from pages where kind='technosphere'),20,'sparse product first page fills');
select is((select page#>>'{rows,19,internalId}' from pages where kind='technosphere'),'1159','sparse product ordering');
select is((select page#>>'{rows,0,internalId}' from pages where kind='waste'),'67','sparse waste first match');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000','technosphere',(select page->>'nextCursor' from pages where kind='technosphere'),20)#>>'{rows,0,internalId}','1220','product continuation starts after real cursor');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000','waste',(select page->>'nextCursor' from pages where kind='waste'),20)->'nextCursor','null'::jsonb,'sparse waste partial final page has no false cursor');
reset role;
create temp table saved_support as select pg_get_functiondef('private.display_exchange_support_v1(integer,jsonb,jsonb)'::regprocedure) definition;
create temporary sequence support_calls;
grant usage,select on sequence support_calls to portal_display_executor;
do $$begin execute replace((select definition from saved_support),E'begin\n',E'begin\n  perform nextval(''pg_temp.support_calls'');\n'); end$$;
update private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1();
set local role anon;
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002556','01.00.000','waste',null,20)->'rows'),20,'2556 distinct refs: waste first page fills');
reset role;
select is((select last_value from support_calls),22::bigint,'sparse kind hydrates only functional unit, page and lookahead');
do $$begin execute (select definition from saved_support); end$$;
update private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1();
create temp table exchange_pages(page jsonb); grant all on exchange_pages to anon;
-- Sparse valid rows, a duplicate straddling the page frontier, malformed IDs,
-- invalid decimals/exact versions and normalized-ID aliases of different kinds.
update public.processes set json=jsonb_set(json,'{processDataSet,exchanges,exchange}',
 jsonb_build_array(pg_temp.exchange_item('1'),pg_temp.exchange_item('2'),pg_temp.exchange_item('3',4),
 pg_temp.exchange_item('4',5),pg_temp.exchange_item('5')||'{"meanAmount":"NaN"}',
 pg_temp.exchange_item('6')||'{"referenceToFlowDataSet":{"@type":"flow data set","@refObjectId":"82400000-0000-4000-8000-000000000003","@version":"99.99.999"}}',
 pg_temp.exchange_item('bad'),pg_temp.exchange_item('99999999999999999'),pg_temp.exchange_item('7',4),
 pg_temp.exchange_item(' 7 ',3),pg_temp.exchange_item('  7 ',5),jsonb_set(pg_temp.exchange_item('8'),'{referenceToFlowDataSet,@refObjectId}','" 82400000-0000-4000-8000-000000000003 "'),
 pg_temp.exchange_item('9')||'{"referenceToFlowDataSet":{"@type":"other","@refObjectId":"82400000-0000-4000-8000-000000000003","@version":"01.00.000"}}',
 pg_temp.exchange_item('10')||'{"referenceToFlowDataSet":{"@type":"flow data set","@refObjectId":"invalid-uuid","@version":"01.00.000"}}',
 pg_temp.exchange_item('11')||'{"referenceToFlowDataSet":{"@type":"flow data set","@refObjectId":{},"@version":1}}',
 pg_temp.exchange_item('2',4)||'{"meanAmount":"bad"}'))
where id='82400000-0000-4000-8000-000000002540';
delete from exchange_pages;
set local role anon;
insert into exchange_pages select api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000','all',null,4);
select is((select jsonb_path_query_array(page,'$.rows[*].internalId') from exchange_pages),'["1","3","4","7"]'::jsonb,'all-array duplicate detection and invalid support precede page filling');
select is((select page#>>'{rows,3,kind}' from exchange_pages),'elementary','normalized-ID alias group orders by kind');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000','all',(select page->>'nextCursor' from exchange_pages),4)#>'{rows,0,kind}','"technosphere"'::jsonb,'same numeric ID with later kind continues correctly');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000','all',(select page->>'nextCursor' from exchange_pages),4)->'nextCursor','null'::jsonb,'final partial page has no false continuation');
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000','waste',null,1)->'rows'),1,'kind filter fills a page after skipped kinds');
reset role;
update private.dataset_display_settings set is_visible=false where dataset_kind='unitgroup' and dataset_id='82400000-0000-4000-8000-000000000001';
set local role anon;
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002540','01.00.000')->'rows'),0,'hidden exact support still blocks numerics');
reset role;
select lives_ok($q$select private.portal_display_assert_contract_v1()$q$,'original helper and manifest restored');
update private.dataset_display_settings set is_visible=true where dataset_kind='unitgroup' and dataset_id='82400000-0000-4000-8000-000000000001';
-- Bound bulk fixture maintenance separately, restoring the API budget below.
set local statement_timeout='60s';
update public.flows set json=jsonb_set(json,'{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}','"Elementary flow"') where id::text like '82400000%' and right(id::text,12)::bigint>10000;
set local statement_timeout='8s';
select is(current_setting('statement_timeout'),'8s','zero-match probes retain the eight-second statement budget');
set local role anon;
select is(jsonb_array_length(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002556','01.00.000','waste',null,20)->'rows'),0,'2556 nonmatching exact refs return an empty page');
select is(api.portal_list_process_exchanges_v2(array['worldsteel'],'82400000-0000-4000-8000-000000002556','01.00.000','technosphere',null,20)->'nextCursor','null'::jsonb,'zero matches have no continuation');
reset role;
select * from finish();
rollback;
