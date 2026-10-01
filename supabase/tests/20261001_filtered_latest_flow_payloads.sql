-- Database #761: historical-match/latest-visible and paged payload contracts.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public;
select no_plan();

-- This reader-only fixture leaves every source/projection writer change rolled back.
alter table public.flows disable trigger user;
create function pg_temp.flow_payload_761(p_type text,p_class jsonb,p_category jsonb default null)
returns jsonb language sql immutable as $$
select jsonb_build_object('repairCase','filtered-latest-761','flowDataSet',jsonb_build_object(
 'flowInformation',jsonb_build_object('dataSetInformation',jsonb_build_object(
 'classificationInformation',jsonb_build_object(
 'common:classification',jsonb_build_object('common:class',p_class),
 'common:elementaryFlowCategorization',jsonb_build_object('common:category',p_category)))),
 'modellingAndValidation',jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet',p_type))))
$$;
insert into public.flows(id,version,json,user_id,team_id,state_code,created_at,modified_at)
select ('76120000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,version,payload,
 case when n in (5,7,8,9) then '76130000-0000-4000-8000-000000000002'::uuid
 else '76130000-0000-4000-8000-000000000001'::uuid end,
 '76130000-0000-4000-8000-000000000011',state_code,
 '2026-10-01'::timestamptz,case when n=2 then null else '2026-10-01'::timestamptz end
from (values
 (1,'01.00.000',100,pg_temp.flow_payload_761('Product flow','[{"@classId":"old"}]')),
 (1,'01.00.001',100,pg_temp.flow_payload_761('Elementary flow','[{"@classId":"new"}]')),
 (2,'01.00.000',100,pg_temp.flow_payload_761('Product flow','{"@classId":"object"}','{"@catId":"elementary-object","#text":"Resources","@level":"0"}')),
 (3,'01.00.000',100,pg_temp.flow_payload_761('Elementary flow','null','[{"@catId":"air","#text":"Emissions","@level":"0"}]')),
 (4,'01.00.000',100,pg_temp.flow_payload_761('Elementary flow','null','{"@catId":"air","#text":"Emissions","@level":"0"}')),
 (5,'01.00.000',0,pg_temp.flow_payload_761('Product flow','[{"@classId":"private-old"}]')),
 (5,'01.00.001',100,pg_temp.flow_payload_761('Elementary flow','[{"@classId":"public-new"}]')),
 (6,'01.00.000',0,pg_temp.flow_payload_761('Product flow','[{"@classId":"owner-old"}]')),
 (6,'01.00.001',0,pg_temp.flow_payload_761('Elementary flow','[{"@classId":"owner-new"}]')),
 (7,'01.00.000',0,pg_temp.flow_payload_761('Product flow','[{"@classId":"other-private"}]')),
 (8,'01.00.000',-1,pg_temp.flow_payload_761('Product flow','[{"@classId":"example"}]')),
 (9,'01.00.000',200,pg_temp.flow_payload_761('Product flow','[{"@classId":"co"}]'))
) as fixture(n,version,state_code,payload);
set local role authenticated;
select set_config('request.jwt.claim.sub','76130000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"76130000-0000-4000-8000-000000000001"}',true);

select is((select version::text from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}') where id='76120000-0000-4000-8000-000000000001'),
 '01.00.001','a historical type match returns the latest visible version');
select is((select json#>>'{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}') where id='76120000-0000-4000-8000-000000000001'),
 'Elementary flow','hydration returns the latest payload even when it does not match the type');
select is((select max(total_count) from api.get_latest_flow_versions(1,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),2::bigint,'count is distinct matched identities before pagination');
select is((select version::text from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"classification","code":"old"}]}')),
 '01.00.001','historical array classification returns the latest visible version');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"classification","code":"object"}]}')),1::bigint,
 'object classification retains its matching behavior');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"elementary","code":"elementary-object"}]}')),1::bigint,
 'object elementary categories remain filterable');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"elementary","code":"air"}]}')),2::bigint,
 'array and object elementary categories retain equality semantics');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"classification","code":"old"},{"scope":"elementary","code":"elementary-object"}]}')),2::bigint,
 'selected classification entries are alternatives across namespaces');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","asInput":true}') where id='76120000-0000-4000-8000-000000000003'),0::bigint,
 'asInput excludes the existing array Emissions shape');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","asInput":true}') where id='76120000-0000-4000-8000-000000000004'),1::bigint,
 'asInput preserves the legacy object Emissions containment behavior');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","asInput":false}') where id='76120000-0000-4000-8000-000000000003'),1::bigint,
 'false asInput admits Emissions');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"missing","flowType":"Product flow"}')),0::bigint,'residual containment is still required');
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"classification","code":"private-old"}]}')),0::bigint,
 'an invisible historical version cannot admit an otherwise visible identity');
select is((select version::text from api.get_latest_flow_versions(10,1,'my','76130000-0000-4000-8000-000000000001',null,0,
 '{"repairCase":"filtered-latest-761","classification":[{"scope":"classification","code":"owner-old"}]}')),
 '01.00.001','my draft history matches and hydrates only the latest visible owned draft');
select is((select count(*) from api.get_latest_flow_versions(10,1,'my','76130000-0000-4000-8000-000000000002',null,0,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),0::bigint,'my scope cannot bypass another owner draft RLS');
select is((select count(*) from api.get_latest_flow_versions(10,1,'te','',
 '76130000-0000-4000-8000-000000000011',0,'{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),1::bigint,
 'team scope retains actor visibility rather than admitting every team draft');
select is((select count(*) from api.get_latest_flow_versions(10,1,'te','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),0::bigint,'team scope still requires a team id');
select is((select count(*) from api.get_latest_flow_versions(10,1,'ex','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),1::bigint,'authenticated example visibility is preserved');
select is((select count(*) from api.get_latest_flow_versions(10,1,'co','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),1::bigint,'co scope still fixes state 200');
select is((select count(*) from api.get_latest_flow_versions(10,1,'invalid','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),0::bigint,'unknown source remains empty');
select is((select max(total_count) from api.get_latest_flow_versions(1,2,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),2::bigint,'page two retains full count');
select is((select count(*) from api.get_latest_flow_versions(1,3,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),0::bigint,'an empty page has no invented count row');
select is((select id::text from api.get_latest_flow_versions(1,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}','modified_at','desc')),
 '76120000-0000-4000-8000-000000000001','nullable timestamps still sort NULLS LAST');
select is((select id::text from api.get_latest_flow_versions(1,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}','invalid','invalid')),
 '76120000-0000-4000-8000-000000000001','unknown sort falls back to identity order');
select is((select count(*) from api.get_latest_flow_versions(0,0,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),1::bigint,'page bounds retain normalization');
select ok((select bool_and(
 (payload#>>'{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}')
 is not distinct from
 (payload->'flowDataSet'->'modellingAndValidation'->'LCIMethod'->>'typeOfDataSet'))
 from (values (null::jsonb),('null'::jsonb),('[]'::jsonb),('42'::jsonb),
 ('{"flowDataSet":true}'::jsonb),('{"flowDataSet":{"modellingAndValidation":[]}}'::jsonb),
 ('{"flowDataSet":{"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":null}}}}'::jsonb),
 ('{"flowDataSet":{"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":["Product flow"]}}}}'::jsonb),
 ('{"flowDataSet":{"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":123}}}}'::jsonb)) cases(payload)),
 'the existing-index expression preserves missing, malformed and non-string extraction');
select ok((select not prosecdef and proconfig @> array['statement_timeout=60s']
 from pg_proc where oid='api.get_latest_flow_versions(bigint,bigint,text,text,uuid,integer,jsonb,text,text)'::regprocedure),
 'the reader remains an invoker with its unchanged 60-second setting');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"76130000-0000-4000-8000-000000000001","client_id":"76130000-0000-4000-8000-000000000099"}',true);
select is((select count(*) from api.get_latest_flow_versions(10,1,'tg','',null,null,
 '{"repairCase":"filtered-latest-761","flowType":"Product flow"}')),0::bigint,
 'an unregistered OAuth client remains closed by the restrictive relation policy');
select * from finish();
rollback;
