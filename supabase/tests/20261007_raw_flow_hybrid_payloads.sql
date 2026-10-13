-- Full ordered result parity for raw Flow Hybrid at its real API executor boundary.
-- The predecessor is frozen independently of the optimized implementation.
begin;
create extension if not exists pgtap with schema extensions;
\ir fixtures/20261004_flow_lexical_payloads.sql
\ir fixtures/20261007_raw_flow_lexical_predecessor.sql
\ir fixtures/20261007_raw_flow_hybrid_predecessor.sql
set local search_path=public,extensions,auth;
select extensions.no_plan();
select extensions.ok(bool_and((j #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}') is not distinct from
 (j->'flowDataSet'->'modellingAndValidation'->'LCIMethod'->>'typeOfDataSet')),'type-index expression preserves JSON path extraction for noncanonical shapes')
from (values(null::jsonb),('null'::jsonb),('{}'::jsonb),('[]'::jsonb),('true'::jsonb),('{"flowDataSet":[]}'::jsonb),('{"flowDataSet":{"modellingAndValidation":1}}'::jsonb),('{"flowDataSet":{"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":123}}}}'::jsonb),('{"flowDataSet":{"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":["Product flow"]}}}}'::jsonb),('{"flowDataSet":{"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":{"value":"Product flow"}}}}}'::jsonb)) v(j);
-- Grant only in the rolled-back fixture to reproduce the deployed definer role.
grant api_internal_executor to postgres;
do $grant$ begin
 execute format('grant usage,create on schema %I to api_internal_executor',
   (select nspname from pg_namespace where oid=pg_my_temp_schema()));
end $grant$;
alter function pg_temp.raw_flow_hybrid_predecessor(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
grant execute on function pg_temp.raw_flow_hybrid_predecessor(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
-- Both eligible historical versions of one identity contribute to the original
-- RRF. Newer invisible history must not win latest payload selection.
select pg_temp.flow_774_fixture(1,'01.00.002',0,9,'flow774token','invisible-latest');
select pg_temp.flow_774_fixture(10,'01.00.000',100,4,'flow774token','tie');
update public.flows set embedding_ft=(array[1.0::real,
 ((substring(id::text from 35 for 2)::integer+1)::real/30
  +case when version='01.00.001' then 0.003 else 0 end)]||array_fill(0.01::real,array[1022]))::extensions.vector
where id::text like '77400000-%';
-- Equal distances are a separate contract case, with all tied rows admitted.
update public.flows set embedding_ft=(select embedding_ft from public.flows where id='77400000-0000-4000-8000-000000000002' and version='01.00.000')
where id='77400000-0000-4000-8000-000000000010';
update public.flows set modified_at=null where id='77400000-0000-4000-8000-000000000010';
-- Small nonmatching, vector-NULL fillers make Product genuinely selective in
-- ordinary expression-index statistics without entering either result stream.
select pg_temp.flow_774_fixture(1000+n,'01.00.000',100,1,
 'raw793-statistics-only','statistics-only','Elementary flow')
from generate_series(1,100) n;
analyze public.flows;
-- Copy the deployed normalization/statistics prelude, rather than reproducing
-- the gate formula or guessing the boolean. UUID requests are excluded here.
do $gate$
declare source text; prefix text; boundary integer; uuid_start integer; uuid_end integer;
begin
 select prosrc into source from pg_proc where oid=
  'private.search_flows_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])'::regprocedure;
 boundary := strpos(source,'  v_sql := format($sql$');
 uuid_start := strpos(source,'  if exact_query_id is not null then');
 uuid_end := strpos(source,'  json_filter_clause := case');
 if boundary=0 or uuid_start=0 or uuid_end<=uuid_start
    or strpos(source,'use_type_keys')=0 then
  raise exception 'Unrecognized deployed raw793 gate prelude' using errcode='55000';
 end if;
 prefix := left(source,uuid_start-1)
  || '  if exact_query_id is not null then raise exception ''gate probe excludes UUID path'';end if;'
  || substring(source from uuid_end for boundary-uuid_end);
 execute 'create function pg_temp.raw_793_type_gate(query_text text,filter_condition jsonb,
  page_size bigint default 10,page_current bigint default 1,data_source text default ''tg'',
  this_user_id text default '''',team_id_filter uuid default null,state_code_filter integer default null,
  query_terms text[] default array[''flow774token'']) returns boolean language plpgsql security definer
  set search_path=private,api,public,util,extensions,pg_temp as $probe$'
  || prefix || 'return coalesce(use_type_keys,false);end;$probe$';
end $gate$;
grant execute on function pg_temp.raw_793_type_gate(text,jsonb,bigint,bigint,text,text,uuid,integer,text[]) to authenticated;
create function pg_temp.raw_793_page(
 p_before boolean,p_source text default 'tg',p_filter jsonb default '{}',
 p_size integer default 10,p_page integer default 1,p_count integer default 20,
 p_lex double precision default 0.5,p_sem double precision default 0.5,
 p_threshold double precision default 0.5,p_query text default 'flow774token',
 p_terms text[] default array['flow774token'],p_k integer default 10
) returns jsonb language plpgsql as $body$
declare result jsonb; v text:='['||array_to_string(array[1.0::real,0.0::real]||array_fill(0.01::real,array[1022]),',')||']';
begin
 if p_before then
   select coalesce(jsonb_agg(to_jsonb(r)-'ordinality' order by r.ordinality),'[]') into result
   from pg_temp.raw_flow_hybrid_predecessor(p_query,v,p_filter::text,p_threshold,p_count,p_lex,p_sem,p_k,p_source,p_size,p_page,p_terms) with ordinality r;
 else
   select coalesce(jsonb_agg(to_jsonb(r)-'ordinality' order by r.ordinality),'[]') into result
   from api.hybrid_search_flows(p_query,v,p_filter,p_threshold,p_count,p_lex,p_sem,p_k,p_source,p_size,p_page,p_terms) with ordinality r;
 end if;
 return result;
end $body$;
grant execute on function pg_temp.raw_793_page(boolean,text,jsonb,integer,integer,integer,double precision,double precision,double precision,text,text[],integer) to anon,authenticated;
create function pg_temp.raw_793_lexical_page(p_before boolean,p_filter jsonb default '{}',p_source text default 'tg',p_size bigint default 10,p_page bigint default 1,p_team uuid default null,p_state integer default null)
returns jsonb language plpgsql as $body$
declare result jsonb;
begin
 if p_before then
  select coalesce(jsonb_agg(to_jsonb(r)-'ordinality' order by r.ordinality),'[]') into result
  from pg_temp.raw_flow_lexical_predecessor('flow774token',p_filter,p_size,p_page,p_source,'',p_team,p_state,array['flow774token']) with ordinality r;
 else
  select coalesce(jsonb_agg(to_jsonb(r)-'ordinality' order by r.ordinality),'[]') into result
  from api.search_flows_latest('flow774token',p_filter,'{}',p_size,p_page,p_source,'',p_team,p_state,array['flow774token']) with ordinality r;
 end if;
 return result;
end $body$;
grant execute on function pg_temp.raw_793_lexical_page(boolean,jsonb,text,bigint,bigint,uuid,integer) to authenticated,anon;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"77400000-0000-4000-8000-000000000901"}',true);
select extensions.ok(pg_temp.raw_793_type_gate('flow774token','{"flowType":"Product flow"}',data_source=>s,
 team_id_filter=>case when s='te' then '77400000-0000-4000-8000-000000000903'::uuid end),
 'actual selective Product gate enabled for '||s)
from unnest(array['tg','co','my','te','ex']) s;
select extensions.ok(not pg_temp.raw_793_type_gate('flow774token',f,data_source=>s),
 'actual common/no-type strategy fallback for '||s||' '||f::text)
from unnest(array['tg','co','my','te','ex']) s cross join
 unnest(array['{}','{"flowType":"Elementary flow"}','{"flowType":"Product flow,Elementary flow"}']::jsonb[]) f;
-- Database #838 fixes the frozen predecessor's C1 historical match returning
-- the newer C9 payload. Only this known synthetic identity changes: its expected
-- exact payload comes directly from the independently bound fixture version,
-- not from the candidate matcher. All nonclassification parity stays literal.
create function pg_temp.issue838_expected_classification_payload(p_previous jsonb,p_filter jsonb)
returns jsonb language sql stable as $$
 select coalesce(jsonb_agg(case
   when p_filter @> '{"classification":[{"scope":"classification","code":"C1"}]}'::jsonb
     and item->>'id'='77400000-0000-4000-8000-000000000001'
   then item||jsonb_build_object('version','01.00.000','json',source.json,'modified_at',source.modified_at)
   else item end order by ordinal),'[]'::jsonb)
 from jsonb_array_elements(p_previous) with ordinality as rows(item,ordinal)
 left join public.flows source on source.id='77400000-0000-4000-8000-000000000001'::uuid and source.version='01.00.000';
$$;
select extensions.is(pg_temp.raw_793_lexical_page(false,p_source=>s,p_filter=>f),pg_temp.issue838_expected_classification_payload(pg_temp.raw_793_lexical_page(true,p_source=>s,p_filter=>f),f),'full ordered lexical parity with classification-correct exact fixture payload')
from unnest(array['tg','co','my','te','ex','TG','unknown',null]::text[]) s cross join unnest(array['{}','{"flowType":"Product flow"}','{"asInput":true}','{"label":"old"}','{"classification":[{"scope":"classification","code":"C1"}]}','{"classification":[{"scope":"elementary","code":"E1"}]}']::jsonb[]) f;
select extensions.is(pg_temp.raw_793_lexical_page(false,p_size=>n,p_page=>p),pg_temp.raw_793_lexical_page(true,p_size=>n,p_page=>p),'full ordered lexical count and pagination parity') from unnest(array[1,2,99,200,800,1000]) n cross join unnest(array[1,2,100]) p;
select extensions.is(pg_temp.raw_793_lexical_page(false,p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000903'),pg_temp.raw_793_lexical_page(true,p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000903'),'explicit readable team lexical parity');
select extensions.is(pg_temp.raw_793_lexical_page(false,p_filter=>'{"flowType":"Product flow"}',p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000903'),pg_temp.raw_793_lexical_page(true,p_filter=>'{"flowType":"Product flow"}',p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000903'),'selective Product readable-team full ordered lexical parity');
select extensions.ok(jsonb_array_length(pg_temp.raw_793_lexical_page(false,p_filter=>'{"flowType":"Product flow"}',p_source=>'te',p_team=>'77400000-0000-4000-8000-000000000903'))>0,'selective Product readable-team parity contains an authorized row');
select extensions.is(pg_temp.raw_793_page(false,p_source=>s),pg_temp.raw_793_page(true,p_source=>s),'complete raw Hybrid output parity for scope '||coalesce(s,'NULL'))
from unnest(array['tg','co','my','te','ex','TG',' tg ','unknown',null]::text[]) s;
select extensions.is(pg_temp.raw_793_page(false,p_filter=>f),pg_temp.issue838_expected_classification_payload(pg_temp.raw_793_page(true,p_filter=>f),f),'filter history/latest full payload with classification-correct fixture '||f::text)
from unnest(array['{}','{"flowType":"Product flow"}','{"flowType":"Elementary flow"}','{"asInput":true}','{"asInput":false}','{"label":"old"}','{"classification":[{"scope":"classification","code":"C1"}]}','{"classification":[{"scope":"elementary","code":"E1"}]}']::jsonb[]) f;
select extensions.is(pg_temp.raw_793_page(false,p_size=>n,p_page=>p),pg_temp.raw_793_page(true,p_size=>n,p_page=>p),'page/count parity size='||n||' page='||p)
from unnest(array[1,2,10,80,100]) n cross join unnest(array[1,2,5]) p;
select extensions.is(pg_temp.raw_793_page(false,p_lex=>l,p_sem=>w),pg_temp.raw_793_page(true,p_lex=>l,p_sem=>w),'RRF multiplicity/zero/NULL weights parity')
from (values(1.0::double precision,0.0::double precision),(0.0,1.0),(0.0,0.0),(null,0.5),(0.5,null),(null,null),(0.8,0.2)) v(l,w);
select extensions.is(pg_temp.raw_793_page(false,p_count=>n),pg_temp.raw_793_page(true,p_count=>n),'match count and semantic duplicates parity '||coalesce(n::text,'NULL'))
from unnest(array[1,2,20,80,100,null]) n;
select extensions.is(pg_temp.raw_793_page(false,p_threshold=>t),pg_temp.raw_793_page(true,p_threshold=>t),'threshold parity') from unnest(array[0.0,0.5,1.0,null]::double precision[]) t;
select extensions.is(pg_temp.raw_793_page(false,p_query=>q,p_terms=>array[q]),pg_temp.raw_793_page(true,p_query=>q,p_terms=>array[q]),'UUID/no-match/literal query parity')
from unnest(array['77400000-0000-4000-8000-000000000001','no-such-raw793-token','flow774token OR "invalid"']) q;
select extensions.is(pg_temp.raw_793_page(false,p_terms=>null),pg_temp.raw_793_page(true,p_terms=>null),'NULL terms fall back unchanged');
select extensions.is(pg_temp.raw_793_page(false,p_terms=>array[]::text[]),pg_temp.raw_793_page(true,p_terms=>array[]::text[]),'empty terms fall back unchanged');
select extensions.is(pg_temp.raw_793_page(false,p_size=>null,p_page=>null,p_count=>null),pg_temp.raw_793_page(true,p_size=>null,p_page=>null,p_count=>null),'NULL defaults unchanged');
select extensions.is(pg_temp.raw_793_page(false,p_size=>0,p_page=>0),pg_temp.raw_793_page(true,p_size=>0,p_page=>0),'nonpositive lower normalization unchanged');
select extensions.ok(exists(select 1 from jsonb_array_elements(pg_temp.raw_793_page(false)) r where r->>'id'='77400000-0000-4000-8000-000000000001' and r->>'version'='01.00.001' and r->'json'->>'label'='latest'),'historical match hydrates latest visible nonmatching payload');
select extensions.ok(not exists(select 1 from jsonb_array_elements(pg_temp.raw_793_page(false)) r where r->'json'->>'label' in ('invisible-latest','foreign','foreign-team')),'public path excludes newer private and foreign rows');
select extensions.ok(jsonb_array_length(pg_temp.raw_793_page(false,p_size=>1,p_lex=>0,p_sem=>0))=1,'zero-weight candidates still supply rows');
select extensions.ok((pg_temp.raw_793_page(false,p_size=>1)->0->>'total_count')::integer>1,'total count remains before page');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"77400000-0000-4000-8000-000000000902"}',true);
select extensions.is(pg_temp.raw_793_page(false,p_source=>'my'),pg_temp.raw_793_page(true,p_source=>'my'),'other actor own scope parity');
select extensions.is(pg_temp.raw_793_page(false,p_source=>'te'),pg_temp.raw_793_page(true,p_source=>'te'),'nonmember scope parity');
reset role;
delete from private.roles where user_id='77400000-0000-4000-8000-000000000901';
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"77400000-0000-4000-8000-000000000901"}',true);
select extensions.is(pg_temp.raw_793_page(false,p_source=>'te'),pg_temp.raw_793_page(true,p_source=>'te'),'revoked team membership parity');
select extensions.is(pg_temp.raw_793_page(false,p_source=>'te'),'[]'::jsonb,'revoked team denied');
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select extensions.is(pg_temp.raw_793_page(false,p_source=>'my'),'[]'::jsonb,'missing actor denied');
reset role;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select extensions.is(pg_temp.raw_793_page(false,p_source=>s),pg_temp.raw_793_page(true,p_source=>s),'anonymous source parity '||s) from unnest(array['tg','co','my','te','ex']) s;
reset role;
-- Removing the index also removes its real statistics. The enclosing rollback
-- restores both; do not manufacture catalog rows or force a planner method.
drop index public.flows_json_typeofdataset;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"77400000-0000-4000-8000-000000000901"}',true);
select extensions.ok(not pg_temp.raw_793_type_gate('flow774token','{"flowType":"Product flow"}',data_source=>s),
 'actual missing-statistics Product fallback for '||s)
from unnest(array['tg','co','my','te','ex']) s;
select extensions.is(pg_temp.raw_793_lexical_page(false,p_filter=>'{"flowType":"Product flow"}',p_source=>s,
 p_team=>case when s='te' then '77400000-0000-4000-8000-000000000903'::uuid end),
 pg_temp.raw_793_lexical_page(true,p_filter=>'{"flowType":"Product flow"}',p_source=>s,
 p_team=>case when s='te' then '77400000-0000-4000-8000-000000000903'::uuid end),
 'missing-statistics Product independent lexical parity for '||s)
from unnest(array['tg','co','my','te','ex']) s;
reset role;
select * from extensions.finish();
rollback;
