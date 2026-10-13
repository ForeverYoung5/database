-- Database #838: classification is an authoritative complete-set predicate,
-- never a page-local UI filter. Synthetic data and all effects roll back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,api,private,auth;
select no_plan();

select ok(not has_function_privilege('anon','private.dataset_catalog_filter_matches(text,jsonb,jsonb)','execute'),'matcher stays private');
select ok(not has_function_privilege('authenticated','private.dataset_catalog_source_json(text,uuid,text)','execute'),'raw exact source lookup stays private');
select ok(not has_function_privilege('anon','api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text)','execute'),'raw actor catalog does not add anonymous authority');
select ok((select proowner='api_internal_executor'::regrole and proconfig @> array['row_security=on'] from pg_proc where oid='api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text)'::regprocedure),'catalog retains raw RLS under NOBYPASSRLS internal owner');
select ok(not has_function_privilege('service_role','api.query_dataset_catalog(text,text,jsonb,integer,uuid,integer,integer,text,text,boolean,text)','execute'),'new actor catalog grants no service authority');
select ok(has_function_privilege('next_public_search_executor','private.dataset_catalog_filter_matches(text,jsonb,jsonb)','execute'),'public candidate owner can use pure matcher');
select ok(not has_schema_privilege('api_internal_executor','private','create'),'borrowed private CREATE authority restored');
select ok(not has_schema_privilege('next_public_search_executor','private','create'),'public owner CREATE authority restored');
select ok(not pg_has_role('postgres','api_internal_executor','SET'),'borrowed internal SET authority restored');

create function pg_temp.issue838_document(kind text,leaf text default 'D',systems_array boolean default true) returns jsonb
language plpgsql immutable as $$
declare root text; information text; classification jsonb; document jsonb;
begin
  root := case kind when 'process' then 'processDataSet' when 'flow' then 'flowDataSet' when 'lifecyclemodel' then 'lifeCycleModelDataSet' when 'source' then 'sourceDataSet' when 'contact' then 'contactDataSet' when 'unitgroup' then 'unitGroupDataSet' else 'flowPropertyDataSet' end;
  information := case kind when 'process' then 'processInformation' when 'flow' then 'flowInformation' when 'lifecyclemodel' then 'lifeCycleModelInformation' when 'source' then 'sourceInformation' when 'contact' then 'contactInformation' when 'unitgroup' then 'unitGroupInformation' else 'flowPropertiesInformation' end;
  classification := jsonb_build_object('@name','A','common:class',jsonb_build_array(jsonb_build_object('@level','0','@classId','C','#text','different language'),jsonb_build_object('@level','1','@classId',leaf,'#text','different label')));
  if systems_array then classification := jsonb_build_array(classification,jsonb_build_object('@name','B','common:class',jsonb_build_array(jsonb_build_object('@level','0','@classId','X'),jsonb_build_object('@level','1','@classId','D')))); end if;
  document := jsonb_build_object(root,jsonb_build_object(information,jsonb_build_object('dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName',jsonb_build_object('@xml:lang','en','#text','Issue838Needle')),'common:name',jsonb_build_object('@xml:lang','en','#text','Issue838Needle'),'classificationInformation',jsonb_build_object('common:classification',classification)),
    'time',jsonb_build_object('common:referenceYear','2024'),'geography',jsonb_build_object('locationOfOperationSupplyOrProduction',jsonb_build_object('@location','CN'),'locationOfSupply',jsonb_build_object('@location','CN')))),
    'issue838Reference','83800000-0000-4000-8000-000000000099','label','Issue838Needle');
  if kind='process' then
    document := jsonb_set(document,'{processDataSet,modellingAndValidation}', '{"LCIMethodAndAllocation":{"typeOfDataSet":"Unit process, single operation"}}');
  elsif kind='flow' then
    document := jsonb_set(document,'{flowDataSet,modellingAndValidation}', '{"LCIMethod":{"typeOfDataSet":"Product flow"}}');
  end if;
  return document;
end;
$$;

select ok(private.dataset_catalog_classification_matches('process',pg_temp.issue838_document('process'), '[{"scope":"classification","code":"D","system":"A","path":["C","D"]}]'),'multisystem source matches the exact system path');
select ok(not private.dataset_catalog_classification_matches('process',pg_temp.issue838_document('process','Z'), '[{"scope":"classification","code":"D","system":"A","path":["C","D"]}]'),'cannot join an ancestor in A to a leaf in B');
select ok(private.dataset_catalog_classification_matches('process',pg_temp.issue838_document('process'), '[{"scope":"classification","code":"C","system":"A","path":["C"]}]'),'parent path includes descendants');
select ok(private.dataset_catalog_classification_matches('process',pg_temp.issue838_document('process','D',false), '[{"scope":"classification","code":"D","system":"A","path":["C","D"]}]'),'classification singleton container works');
select ok(private.dataset_catalog_classification_matches('process','{"processDataSet":{"processInformation":{"dataSetInformation":{"classificationInformation":{"common:classification":{"common:class":{"@classId":"C","@level":"0"}}}}}}}', '[{"scope":"classification","code":"C","path":["C"]}]'),'both singleton levels work with unnamed legacy system');
select ok(not private.dataset_catalog_classification_matches('process','{"processDataSet":{"processInformation":{"dataSetInformation":{"classificationInformation":{"common:classification":{"common:class":[{"@classId":"C","@level":"0"},{"@classId":"D","@level":"0"}]}}}}}}', '[{"scope":"classification","code":"D","path":["C","D"]}]'),'duplicate levels cannot stand in for a complete path');
select ok(private.dataset_catalog_classification_matches('flow','{"flowDataSet":{"flowInformation":{"dataSetInformation":{"classificationInformation":{"common:elementaryFlowCategorization":[{"@name":"E","common:category":[{"@catId":"air","@level":"0"},{"@catId":"urban","@level":"1"}]}]}}}}}', '[{"scope":"elementary","code":"urban","system":"E","path":["air","urban"]}]'),'elementary namespace and repeated systems work');
select throws_ok($$select private.dataset_catalog_filter_validate('{"classification":[{"scope":"classification","code":"D","path":["C","Z"]}]}')$$,'22023',null,'invalid final path code rejects before querying');
select throws_ok($$select private.dataset_catalog_filter_validate('{"classification":[{"scope":"unknown","code":"C"}]}')$$,'22023',null,'unknown scope rejects');
select throws_ok($$select private.dataset_catalog_filter_validate('{"classification":[{"scope":"classification","code":"C","system":null}]}')$$,'22023',null,'malformed system rejects');
select throws_ok($$select api.query_dataset_catalog('contact',p_filter_condition=>'{"classification":[{"scope":"elementary","code":"air"}]}')$$,'22023',null,'non-Flow elementary filter rejects before source scan');
select throws_ok($$select api.search_dataset_uuid_mentions_page('process','83800000-0000-4000-8000-000000000099',p_filter_condition=>'{"classification":[{"scope":"elementary","code":"air"}]}')$$,'22023',null,'non-Flow elementary UUID filter rejects before scan');
select throws_ok($$select api.query_dataset_catalog('process',p_page_size=>101)$$,'22023',null,'excess page size rejects');
select throws_ok($$select api.query_dataset_catalog('process',p_page_current=>2147483647)$$,'22023',null,'offset overflow rejects');
select throws_ok($$select api.search_dataset_uuid_mentions_page('all','83800000-0000-4000-8000-000000000099',p_filter_condition=>'{"sourceEntityKinds":["bad"]}')$$,'22023',null,'mixed UUID kind allowlist rejects invalid input');

-- Writer, webhook and projection triggers are disabled only during fixture
-- construction. The real reader authorization and ordinary constraints remain.
set local session_replication_role=replica;
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data) values
 ('83800000-0000-4000-8000-000000000001','authenticated','authenticated','issue838-owner@example.invalid','{}','{}'),
 ('83800000-0000-4000-8000-000000000002','authenticated','authenticated','issue838-outsider@example.invalid','{}','{}');
insert into private.users(id,raw_user_meta_data,contact) values
 ('83800000-0000-4000-8000-000000000001','{}',null),('83800000-0000-4000-8000-000000000002','{}',null);
insert into private.teams(id,json,rank,is_public) values
 ('83800000-0000-4000-8000-000000000003','{"name":"Issue838Team"}',1,false),
 ('00000000-0000-0000-0000-000000000000','{"name":"System"}',0,false) on conflict(id) do nothing;
insert into private.roles(user_id,team_id,role) values
 ('83800000-0000-4000-8000-000000000001','83800000-0000-4000-8000-000000000003','owner'),
 ('83800000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','data_product_manager');
do $$
declare table_name text; kind text; state integer; index integer; identifier uuid; document jsonb;
begin
  for table_name,kind in select * from (values ('processes','process'),('flows','flow'),('lifecyclemodels','lifecyclemodel'),('sources','source'),('contacts','contact'),('unitgroups','unitgroup'),('flowproperties','flowproperty')) tables(table_name,kind) loop
    foreach state in array array[100,200,0,-1] loop
      if state=200 and kind in ('lifecyclemodel','source','contact') then continue; end if;
      for index in 1..65 loop
        identifier := ('83800000-0000-4000-8'||case state when 100 then '100' when 200 then '200' when 0 then '300' else '400' end||'-'||lpad(index::text,12,'0'))::uuid;
        document := pg_temp.issue838_document(kind,case when index%2=0 then 'Z' else 'D' end,index%3<>0);
        execute format('insert into public.%I(id,version,state_code,user_id,team_id,json,json_ordered,search_text,embedding_ft,created_at,modified_at)
          values($1,''01.00.001'',$2,$3,$4,$5,$5::json,array[''Issue838Needle''],$6::extensions.vector,now(),now())',table_name)
        using identifier,state,'83800000-0000-4000-8000-000000000001'::uuid,'83800000-0000-4000-8000-000000000003'::uuid,document,
          '['||array_to_string(array_prepend('1',array_fill('0'::text,array[1023])),',')||']';
      end loop;
    end loop;
    -- Two versions with distinct classification. UUID must select latest before
    -- matching, while ordinary catalog list selects latest *matching* version.
    identifier := '83800000-0000-4000-8100-000000000090';
    execute format('insert into public.%I(id,version,state_code,user_id,team_id,json,json_ordered,search_text)
       values($1,''01.00.001'',100,$2,$3,$4,$4::json,array[''Issue838Needle'']),($1,''02.00.001'',100,$2,$3,$5,$5::json,array[''Issue838Needle''])',table_name)
      using identifier,'83800000-0000-4000-8000-000000000001'::uuid,'83800000-0000-4000-8000-000000000003'::uuid,pg_temp.issue838_document(kind),pg_temp.issue838_document(kind,'Z');
  end loop;
end;
$$;
do $$
declare table_name text; kind text;
begin
  for table_name,kind in select * from (values ('processes','process'),('flows','flow'),('lifecyclemodels','lifecyclemodel'),('sources','source'),('contacts','contact'),('unitgroups','unitgroup'),('flowproperties','flowproperty')) tables(table_name,kind) loop
    execute format('insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible) select $1,id,version,true from public.%I where state_code=100',table_name) using kind;
  end loop;
end;
$$;
-- Protected state-120 process is owned by the actor, but the restrictive raw
-- SELECT policy still denies generic reads. Dedicated product APIs own it.
insert into public.processes(id,version,state_code,user_id,json,json_ordered,search_text)
select '83800000-0000-4000-8500-000000000120','01.00.001',120,'83800000-0000-4000-8000-000000000001',document,document::json,array['Issue838Needle']
from (select pg_temp.issue838_document('process') as document) fixture;
-- Mirror the existing transactional public candidate sidecar for the fixture;
-- skipped source triggers must not create an artificial projection-coverage gap.
grant api_internal_executor to postgres with set true;
set local role api_internal_executor;
insert into private.next_hybrid_public_candidates_v2(dataset_kind,id,version,state_code,team_id,dataset_type,is_emission,classification_codes,elementary_codes,source_modified_at)
select 'process',id,version,state_code,team_id,json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}',false,'{}'::text[],'{}'::text[],modified_at
  from public.processes where state_code in (100,200) and embedding_ft is not null
union all select 'flow',id,version,state_code,team_id,json #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}',false,'{}'::text[],'{}'::text[],modified_at
  from public.flows where state_code in (100,200) and embedding_ft is not null;
reset role;
set local session_replication_role=origin;

create function pg_temp.issue838_read_assertions() returns setof text language plpgsql as $$
declare kind text; table_name text; source text; count_rows bigint; count_total bigint; version_text text; page_json jsonb;
  filter_json jsonb := '{"classification":[{"scope":"classification","code":"D","system":"A","path":["C","D"]}]}';
  vector_text text := '['||array_to_string(array_prepend('1',array_fill('0'::text,array[1023])),',')||']';
begin
 for table_name,kind in select * from (values ('processes','process'),('flows','flow'),('lifecyclemodels','lifecyclemodel'),('sources','source'),('contacts','contact'),('unitgroups','unitgroup'),('flowproperties','flowproperty')) tables(table_name,kind) loop
  foreach source in array array['tg','co','my','te','ex'] loop
    if source='co' and kind in ('lifecyclemodel','source','contact') then
      select count(*) into count_rows from api.query_dataset_catalog(kind,source,filter_json);
      return next extensions.is(count_rows,0::bigint,kind||': commercial scope has no schema-admissible rows');
      continue;
    end if;
    select count(*),max(total_count) into count_rows,count_total from api.query_dataset_catalog(kind,source,filter_json,
      p_state_code=>case source when 'my' then 0 when 'te' then 0 else null end,
      p_team_id=>'83800000-0000-4000-8000-000000000003',p_page_size=>10,p_page_current=>3);
    return next extensions.is(count_rows,10::bigint,kind||'/'||source||': third filtered list page is full');
    return next extensions.is(count_total,case source when 'tg' then 34 else 33 end::bigint,kind||'/'||source||': total is complete filtered set');
    select count(*),max(total_count) into count_rows,count_total from api.search_dataset_uuid_mentions_page(kind,
      '83800000-0000-4000-8000-000000000099',source,filter_json,
      p_state_code=>case source when 'my' then 0 when 'te' then 0 else null end,
      p_team_id=>'83800000-0000-4000-8000-000000000003',p_page_size=>10,p_page_current=>3);
    return next extensions.is(count_rows,10::bigint,kind||'/'||source||': third filtered UUID page is full');
    return next extensions.is(count_total,33::bigint,kind||'/'||source||': UUID total excludes nonmatching latest version');
    execute format('select count(*),max(total_count) from api.search_%I(query_text=>''Issue838Needle'',filter_condition=>$1,data_source=>$2,
      state_code_filter=>$3,team_id_filter=>$4,this_user_id=>''83800000-0000-4000-8000-000000000001'',page_size=>10,page_current=>3)',table_name)
      into count_rows,count_total using filter_json,source,case source when 'my' then 0 when 'te' then 0 else null end,'83800000-0000-4000-8000-000000000003'::uuid;
    return next extensions.is(count_rows,10::bigint,kind||'/'||source||': lexical condition applied before page');
    return next extensions.ok(count_total>=33,kind||'/'||source||': lexical total includes complete matching set');
    if kind in ('process','flow') then
      execute format('select count(*),max(total_count) from api.hybrid_search_%I_versions_v2(query_text=>''Issue838Needle'',query_embedding=>$1,filter_condition=>$2,
        data_source=>$3,page_size=>10,page_current=>3,lexical_weight=>1,semantic_weight=>0,state_code_filter=>$4,team_id_filter=>$5)',kind)
        into count_rows,count_total using vector_text,filter_json,source,case source when 'my' then 0 when 'te' then 0 else null end,'83800000-0000-4000-8000-000000000003'::uuid;
    else
      execute format('select count(*),max(total_count) from api.%I(query_text=>''Issue838Needle'',query_embedding=>$1,filter_condition=>$2,
        data_source=>$3,page_size=>10,page_current=>3,lexical_weight=>1,semantic_weight=>0,state_code_filter=>$4,team_id_filter=>$5)',
        case kind when 'lifecyclemodel' then 'hybrid_search_lifecyclemodels_filtered' else 'hybrid_search_'||table_name end)
        into count_rows,count_total using vector_text,filter_json,source,case source when 'my' then 0 when 'te' then 0 else null end,'83800000-0000-4000-8000-000000000003'::uuid;
    end if;
    return next extensions.is(count_rows,10::bigint,kind||'/'||source||': Hybrid classification applied during lexical recall');
    return next extensions.ok(count_total>=33,kind||'/'||source||': Hybrid count includes matching recalls');
    if kind in ('process','flow') then
      execute format('select count(*),max(total_count) from api.hybrid_search_%I_versions_v2(query_text=>''No lexical match'',query_embedding=>$1,filter_condition=>$2,
        data_source=>$3,page_size=>10,page_current=>3,lexical_weight=>0,semantic_weight=>1,state_code_filter=>$4,team_id_filter=>$5)',kind)
        into count_rows,count_total using vector_text,filter_json,source,case source when 'my' then 0 when 'te' then 0 else null end,'83800000-0000-4000-8000-000000000003'::uuid;
    else
      execute format('select count(*),max(total_count) from api.%I(query_text=>''No lexical match'',query_embedding=>$1,filter_condition=>$2,
        data_source=>$3,match_count=>100,page_size=>10,page_current=>3,lexical_weight=>0,semantic_weight=>1,state_code_filter=>$4,team_id_filter=>$5)',
        case kind when 'lifecyclemodel' then 'hybrid_search_lifecyclemodels_filtered' else 'hybrid_search_'||table_name end)
        into count_rows,count_total using vector_text,filter_json,source,case source when 'my' then 0 when 'te' then 0 else null end,'83800000-0000-4000-8000-000000000003'::uuid;
    end if;
    return next extensions.is(count_rows,10::bigint,kind||'/'||source||': semantic-only classification applied before recall limit');
    return next extensions.ok(count_total>=33,kind||'/'||source||': semantic-only complete matching recall count');

  end loop;
  select version into version_text from api.query_dataset_catalog(kind,'tg',filter_json||'{"datasetId":"83800000-0000-4000-8100-000000000090"}',p_version_scope=>'all');
  return next extensions.is(version_text,'01.00.001',kind||': all-version list retains exact matching version');
  execute format('select version from api.search_%I(query_text=>''83800000-0000-4000-8100-000000000090'',filter_condition=>$1,data_source=>''tg'')',table_name)
    into version_text using filter_json;
  return next extensions.is(version_text,'01.00.001',kind||': lexical exact UUID hydrates latest matching classification version');
  execute format('select version from api.search_%I(query_text=>''83800000-0000-4000-8100-000000000090'',data_source=>''tg'')',table_name)
    into version_text;
  return next extensions.is(version_text,'02.00.001',kind||': no-class lexical exact UUID retains latest-visible version');
  execute format('select version from api.search_%I(query_text=>''Issue838Needle'',filter_condition=>$1,data_source=>''tg'',page_size=>100) where id=''83800000-0000-4000-8100-000000000090''',table_name)
    into version_text using filter_json;
  return next extensions.is(version_text,'01.00.001',kind||': full-text hydration cannot return a newer nonmatching version');
  if kind not in ('process','flow') then
    execute format('select version from api.%I(query_text=>''Issue838Needle'',query_embedding=>$1,filter_condition=>$2,data_source=>''tg'',page_size=>100,lexical_weight=>1,semantic_weight=>0) where id=''83800000-0000-4000-8100-000000000090''',
       case kind when 'lifecyclemodel' then 'hybrid_search_lifecyclemodels_filtered' else 'hybrid_search_'||table_name end)
      into version_text using vector_text,filter_json;
    return next extensions.is(version_text,'01.00.001',kind||': Hybrid latest hydration returns matching JSON/version');
  end if;
  page_json := api.list_dataset_display_candidates_filtered(kind,p_page_size=>10,p_page=>3,p_filter_condition=>filter_json);
  return next extensions.is((page_json->>'total')::bigint,case when kind='process' then 134 when kind in ('lifecyclemodel','source','contact') then 100 else 133 end::bigint,kind||': display candidates filter before complete count across all source states');
  return next extensions.is(jsonb_array_length(page_json->'data'),10,kind||': display candidates third page full');
  return next extensions.ok(not jsonb_path_exists(page_json,'$.data[*].source_json') and not jsonb_path_exists(page_json,'$.data[*].json'),kind||': display response does not expose raw source JSON');
  page_json := api.list_displayed_datasets_filtered(kind,p_page_size=>10,p_page=>3,p_filter_condition=>filter_json);
  return next extensions.is((page_json->>'total')::bigint,34::bigint,kind||': displayed data filters before count');
  return next extensions.is(jsonb_array_length(page_json->'data'),10,kind||': displayed data third page full');
  if kind='process' then
    return next extensions.is(page_json #>> '{data,0,location}','CN','display Process location uses source geographic code');
    return next extensions.is(page_json #>> '{data,0,reference_year}','2024','display Process uses actual reference year');
    return next extensions.is(page_json #>> '{data,0,type_of_data_set}','Unit process, single operation','display Process uses actual dataset type');
  end if;

  select count(*),max(total_count) into count_rows,count_total from api.search_open_data_catalog(kind,p_filter_condition=>filter_json,p_page_size=>10,p_page_current=>3);
  return next extensions.is(count_rows,10::bigint,kind||': Open Data list complete-set classification');
  return next extensions.is(count_total,34::bigint,kind||': Open Data list exact count');
  select count(*),max(total_count) into count_rows,count_total from api.search_open_data_catalog(kind,p_search_mode=>'lexical',p_query_text=>'Issue838Needle',p_filter_condition=>filter_json,p_page_size=>10,p_page_current=>3);
  return next extensions.is(count_rows,10::bigint,kind||': Open Data lexical complete-set classification');
  select count(*),max(total_count) into count_rows,count_total from api.search_open_data_catalog(kind,p_search_mode=>'uuid',p_query_text=>'83800000-0000-4000-8000-000000000099',p_filter_condition=>filter_json,p_page_size=>10,p_page_current=>3);
  return next extensions.is(count_rows,10::bigint,kind||': Open Data UUID complete-set classification');
  select count(*),max(total_count) into count_rows,count_total from api.hybrid_search_open_data_catalog(kind,'Issue838Needle',vector_text,filter_condition=>filter_json,page_size=>10,page_current=>3,lexical_weight=>1,semantic_weight=>0);
  return next extensions.is(count_rows,10::bigint,kind||': Open Data Hybrid filters before recall');
 end loop;
end;
$$;
grant execute on function pg_temp.issue838_read_assertions() to authenticated;
select set_config('request.jwt.claims','{"sub":"83800000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select set_config('request.jwt.claim.sub','83800000-0000-4000-8000-000000000001',true);
set local role authenticated;
select * from pg_temp.issue838_read_assertions();

select is((select count(*) from api.search_dataset_uuid_mentions_page('all','83800000-0000-4000-8000-000000000099',p_filter_condition=>'{"sourceEntityKinds":["process","flow"]}',p_page_size=>100)),100::bigint,'mixed UUID page extends beyond legacy 50-result cap');
select is((select max(total_count) from api.search_dataset_uuid_mentions_page('all','83800000-0000-4000-8000-000000000099',p_filter_condition=>'{"sourceEntityKinds":["process","flow"]}',p_page_size=>100)),132::bigint,'mixed UUID count includes both complete latest sets');
select is((select count(*) from api.query_dataset_catalog('process','my',p_filter_condition=>'{"datasetId":"83800000-0000-4000-8500-000000000120"}',p_state_code=>120,p_version_scope=>'all')),0::bigint,'owner state-120 remains denied by raw RLS');
select is((select count(*) from api.search_dataset_uuid_mentions_page('process','83800000-0000-4000-8000-000000000099','my',p_filter_condition=>'{"datasetId":"83800000-0000-4000-8500-000000000120"}',p_state_code=>120)),0::bigint,'owner state-120 UUID remains denied by raw RLS');
select is((select count(*) from api.query_dataset_catalog('process','all_data',p_filter_condition=>'{"datasetId":"83800000-0000-4000-8500-000000000120"}',p_version_scope=>'all')),0::bigint,'all-data cannot bypass protected result-process read');
select is((select count(*) from api.query_dataset_catalog('process','all_data',p_version_scope=>'all',p_page_size=>100)),100::bigint,'public plus owner all-data uses server pagination');
select is((select max(total_count) from api.query_dataset_catalog('process','all_data',p_version_scope=>'all',p_page_size=>100)),262::bigint,'all-data preserves every public and own version');
select is((select max(total_count) from api.query_dataset_catalog('process','all_data',p_owner_draft_only=>true,p_version_scope=>'all',p_page_size=>100)),132::bigint,'owner draft mode preserves public plus owned drafts only');
select is((select count(*) from api.hybrid_search_process_versions_v2('Issue838Needle','['||array_to_string(array_prepend('1',array_fill('0'::text,array[1023])),',')||']',filter_condition=>'{"classification":[{"scope":"classification","code":"D","system":"A","path":["C","D"]}]}',lexical_weight=>1,semantic_weight=>0,page_size=>100)),34::bigint,'matched Process Hybrid filters exact version before recall');
select is((select count(*) from api.hybrid_search_flow_versions_v2('Issue838Needle','['||array_to_string(array_prepend('1',array_fill('0'::text,array[1023])),',')||']',filter_condition=>'{"classification":[{"scope":"classification","code":"D","system":"A","path":["C","D"]}]}',lexical_weight=>1,semantic_weight=>0,page_size=>100)),34::bigint,'matched Flow Hybrid includes repeated classification systems');
select is((select count(*) from api.search_dataset_uuid_mentions_page('process','83800000-0000-4000-8000-000000000099',p_filter_condition=>'{"typeOfDataSet":"LCI result"}')),0::bigint,'Process UUID type condition executes before count/page');
select is((select count(*) from api.query_dataset_catalog('process',p_filter_condition=>'{"classification":[{"scope":"classification","code":"absent"}]}')),0::bigint,'valid no-result classification returns empty');
select throws_ok($$select api.list_dataset_display_candidates_filtered('all',p_filter_condition=>'{"classification":[{"scope":"classification","code":"C"}]}')$$,'22023',null,'mixed display classification requires selected kind');
reset role;

-- Same-exchange reference identity/version/direction; split facts cannot match.
select ok(private.dataset_catalog_filter_matches('process','{"processDataSet":{"exchanges":{"exchange":[{"exchangeDirection":"Input","referenceToFlowDataSet":{"@refObjectId":"83800000-0000-4000-8000-000000000099","@version":"01.00.001"}},{"exchangeDirection":"Output","referenceToFlowDataSet":{"@refObjectId":"83800000-0000-4000-8000-000000000088","@version":"01.00.001"}}]}}}', '{"flowReference":{"id":"83800000-0000-4000-8000-000000000099","version":"01.00.001","direction":"Input"}}'),'same exchange matches all flow-reference facts');
select ok(not private.dataset_catalog_filter_matches('process','{"processDataSet":{"exchanges":{"exchange":[{"exchangeDirection":"Input","referenceToFlowDataSet":{"@refObjectId":"83800000-0000-4000-8000-000000000099","@version":"01.00.001"}},{"exchangeDirection":"Output","referenceToFlowDataSet":{"@refObjectId":"83800000-0000-4000-8000-000000000088","@version":"01.00.001"}}]}}}', '{"flowReference":{"id":"83800000-0000-4000-8000-000000000099","version":"01.00.001","direction":"Output"}}'),'split exchange direction cannot cross-match');

select set_config('request.jwt.claims','{"sub":"83800000-0000-4000-8000-000000000001","role":"authenticated","client_id":"83800000-0000-4000-8000-000000000098"}',true);
set local role authenticated;
select is((select count(*) from api.query_dataset_catalog('process','my')),0::bigint,'OAuth client without core-read capability cannot bypass restrictive source RLS');
select is((select count(*) from api.search_dataset_uuid_mentions_page('process','83800000-0000-4000-8000-000000000099','my')),0::bigint,'OAuth UUID route retains restrictive core-read admission');
reset role;
select set_config('request.jwt.claims','{"sub":"83800000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select set_config('request.jwt.claim.sub','83800000-0000-4000-8000-000000000002',true);
set local role authenticated;
select is((select count(*) from api.query_dataset_catalog('process','my')),0::bigint,'foreign owner rows remain private');
select is((select count(*) from api.query_dataset_catalog('process','te',p_team_id=>'83800000-0000-4000-8000-000000000003')),0::bigint,'nonmember selected-team list denied');
select is((select count(*) from api.search_dataset_uuid_mentions_page('process','83800000-0000-4000-8000-000000000099','te',p_team_id=>'83800000-0000-4000-8000-000000000003')),0::bigint,'nonmember selected-team UUID denied');
select throws_ok($$select api.list_dataset_display_candidates_filtered('process')$$,'42501',null,'display candidates retain manager role requirement');
reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select set_config('request.jwt.claim.sub','',true);
set local role anon;
select throws_ok($$select api.query_dataset_catalog('process','my')$$,'42501',null,'anonymous owner catalog denied');
select throws_ok($$select api.query_dataset_catalog('process','ex')$$,'42501',null,'anonymous example catalog denied');
select throws_ok($$select api.query_dataset_catalog('process','all_data')$$,'42501',null,'anonymous all-data cannot read owned drafts');
select is((select count(*) from api.search_dataset_uuid_mentions_page('process','83800000-0000-4000-8000-000000000099','my')),0::bigint,'anonymous owner UUID denied');
reset role;
select * from finish();
rollback;
