-- Page/count/filter/actor semantics and the bounded-payload regression.
begin;
create extension if not exists pgtap with schema extensions;
\ir fixtures/20261004_flow_lexical_payloads.sql
select extensions.no_plan();
select extensions.is(jsonb_array_length(pg_temp.flow_774_page()),2,'public latest page has two visible matched IDs');
select extensions.is(pg_temp.flow_774_page()->0->'json'->>'label','latest','historical text match hydrates the latest visible exact version');
select extensions.is(pg_temp.flow_774_page()->0->>'version','01.00.001','latest version is independent of the matching historical version');
select extensions.is(pg_temp.flow_774_page()->0->>'total_count','2','exact total is calculated before page selection');
select extensions.is(pg_temp.flow_774_page()->0->>'rank','1','rank starts at one');
select extensions.is(pg_temp.flow_774_page()->1->>'rank','2','latest modified date deterministically orders equal text scores');
select extensions.is(pg_temp.flow_774_page(p_size=>1,p_page=>2)->0,pg_temp.flow_774_page()->1,'second page preserves full row, global rank and total');
select extensions.is(pg_temp.flow_774_page(p_size=>1,p_page=>3),'[]'::jsonb,'page beyond exact total is empty');
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"flowType":"Product flow"}'),pg_temp.flow_774_page(),'type matches history while hydration still selects latest visible');
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"asInput":false}'),pg_temp.flow_774_page(),'false asInput does not require content filtering');
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"asInput":true}')->0->'json'->>'label','second','asInput excludes only the historical emission match');
-- #838: the fixture's newer version is C9, so an explicit C1 filter must return
-- its matching 01.00.000 body. No-classification history/latest assertions above stay unchanged.
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"classification":[{"scope":"classification","code":"C1"}]}')->0->'json'->>'label','old','explicit classification hydrates the latest matching body rather than newer C9 content');
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"classification":[{"scope":"classification","code":"C1"}]}')->0->>'version','01.00.000','explicit classification preserves the matching historical exact version');
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"classification":[{"scope":"classification","code":"C1"}]}')->0->'json' #>> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class,@classId}','C1','returned classification metadata satisfies the selected code');
select extensions.is(jsonb_array_length(pg_temp.flow_774_page(p_filter=>'{"classification":[{"scope":"elementary","code":"E1"}]}')),2,'array elementary category filtering is retained');
select extensions.is(pg_temp.flow_774_page(p_filter=>'{"label":"old"}')->0->'json'->>'label','latest','residual JSON filters retain historical matching');
select extensions.is(pg_temp.flow_774_page(p_query=>'77400000-0000-4000-8000-000000000001')->0->'json'->>'label','latest','UUID branch keeps exact identity/latest hydration');
select extensions.is(pg_temp.flow_774_page(p_source=>'co')->0->'json'->>'label','contributed','contributed source is isolated');
select extensions.is(pg_temp.flow_774_page(p_source=>'my'),'[]'::jsonb,'missing owner fails closed');
set local role authenticated;
select set_config('request.jwt.claim.sub','77400000-0000-4000-8000-000000000901',true);
select set_config('request.jwt.claim.role','authenticated',true);
select extensions.is(jsonb_array_length(pg_temp.flow_774_page(p_source=>'my')),2,'owner search includes own draft/review but excludes other actors');
select extensions.is(pg_temp.flow_774_page(p_source=>'my',p_state=>0)->0->'json'->>'label','owner','owner explicit state is preserved');
select extensions.is(pg_temp.flow_774_page(p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000903')->0->'json'->>'label','team','readable team scope is preserved');
select extensions.is(pg_temp.flow_774_page(p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000904'),'[]'::jsonb,'foreign team fails closed');
select extensions.is(pg_temp.flow_774_page(p_source=>'ex')->0->'json'->>'label','example','authenticated example visibility is preserved');
reset role;
select extensions.ok(strpos(pg_get_functiondef('private.search_flows_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])'::regprocedure),'paged_rows as materialized')>0,'lexical payload hydration occurs after bounded exact-key pagination');
select * from extensions.finish();
rollback;
