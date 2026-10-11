-- Database #829: real writers and request-scope isolation across cached statements.
-- Reuses the established display-reader fixture; every change rolls back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions,public,auth;
select extensions.no_plan();

create or replace function pg_temp.portal_versions_localized(p_text text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('@xml:lang', 'en', '#text', p_text)
  )
$$;

create or replace function pg_temp.portal_versions_publication(
  p_version text,
  p_license text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'common:dataSetVersion', p_version,
    'common:licenseType', p_license,
    'common:referenceToOwnershipOfDataSet', pg_catalog.jsonb_build_object(
      '@type', 'contact data set',
      '@refObjectId', '52900000-0000-4000-8000-000000000900',
      '@version', '01.00.000',
      '@uri', 's3://portal-private/provider.json',
      'common:shortDescription', pg_temp.portal_versions_localized('Portal Provider')
    )
  )
$$;

create or replace function pg_temp.portal_versions_process_payload(
  p_name text,
  p_version text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'processDataSet', pg_catalog.jsonb_build_object(
      'processInformation', pg_catalog.jsonb_build_object(
        'dataSetInformation', pg_catalog.jsonb_build_object(
          'name', pg_catalog.jsonb_build_object(
            'baseName', pg_temp.portal_versions_localized(p_name)
          ),
          'common:generalComment', pg_temp.portal_versions_localized(p_name || ' summary'),
          'classificationInformation', pg_catalog.jsonb_build_object(
            'common:classification', pg_catalog.jsonb_build_array(
              pg_catalog.jsonb_build_object(
                'common:class', pg_catalog.jsonb_build_object(
                  '@level', '0', '@classId', 'PORTAL-HYBRID', '#text', 'Hybrid fixture'
                )
              )
            )
          )
        ),
        'time', pg_catalog.jsonb_build_object('common:referenceYear', '2024'),
        'geography', pg_catalog.jsonb_build_object(
          'locationOfOperationSupplyOrProduction', pg_catalog.jsonb_build_object(
            '@location', 'CN',
            'descriptionOfRestrictions', pg_temp.portal_versions_localized('China')
          )
        ),
        'technology', pg_catalog.jsonb_build_object(
          'technologyDescriptionAndIncludedProcesses',
          pg_temp.portal_versions_localized('Hybrid fixture technology')
        )
      ),
      'modellingAndValidation', pg_catalog.jsonb_build_object(
        'LCIMethodAndAllocation', pg_catalog.jsonb_build_object(
          'typeOfDataSet', 'Unit process, single operation'
        )
      ),
      'administrativeInformation', pg_catalog.jsonb_build_object(
        'publicationAndOwnership', pg_temp.portal_versions_publication(
          p_version, 'Free of charge for all users and uses'
        )
      ),
      'privateLocator', 's3://portal-private/process/' || p_name
    )
  )
$$;

create or replace function pg_temp.portal_versions_flow_payload(
  p_name text,
  p_version text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'flowDataSet', pg_catalog.jsonb_build_object(
      'flowInformation', pg_catalog.jsonb_build_object(
        'dataSetInformation', pg_catalog.jsonb_build_object(
          'name', pg_catalog.jsonb_build_object(
            'baseName', pg_temp.portal_versions_localized(p_name)
          ),
          'common:generalComment', pg_temp.portal_versions_localized(p_name || ' summary'),
          'classificationInformation', pg_catalog.jsonb_build_object(
            'common:classification', pg_catalog.jsonb_build_array(
              pg_catalog.jsonb_build_object(
                'common:class', pg_catalog.jsonb_build_object(
                  '@level', '0', '@classId', 'PORTAL-HYBRID', '#text', 'Hybrid fixture'
                )
              )
            )
          ),
          'CASNumber', '50-00-0'
        ),
        'geography', pg_catalog.jsonb_build_object(
          'locationOfSupply', pg_catalog.jsonb_build_object(
            '@location', 'CN',
            'descriptionOfRestrictions', pg_temp.portal_versions_localized('China')
          )
        )
      ),
      'modellingAndValidation', pg_catalog.jsonb_build_object(
        'LCIMethod', pg_catalog.jsonb_build_object('typeOfDataSet', 'Product flow')
      ),
      'administrativeInformation', pg_catalog.jsonb_build_object(
        'publicationAndOwnership', pg_temp.portal_versions_publication(
          p_version, 'Free of charge for all users and uses'
        )
      ),
      'objectLocator', 's3://portal-private/flow/' || p_name
    )
  )
$$;


create or replace function util.invoke_edge_function(name text,body jsonb,timeout_milliseconds integer default 300000)
returns void language plpgsql security definer set search_path='' as $$begin return; end$$;
insert into public.processes(id,version,state_code,json) values
 ('80700000-0000-4000-8000-000000000101','01.00.000',0,pg_temp.portal_versions_process_payload('Visible draft process','01.00.000')),
 ('80700000-0000-4000-8000-000000000101','02.00.000',200,pg_temp.portal_versions_process_payload('Other brand process','02.00.000')),
 ('80700000-0000-4000-8000-000000000102','01.00.000',100,pg_temp.portal_versions_process_payload('Hidden approved process','01.00.000'));
insert into public.flows(id,version,state_code,json) values
 ('80700000-0000-4000-8000-000000000103','01.00.000',0,pg_temp.portal_versions_flow_payload('Visible flow','01.00.000'));
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand) values
 ('process','80700000-0000-4000-8000-000000000101','01.00.000',true,'tiangong_lca'),
 ('process','80700000-0000-4000-8000-000000000101','02.00.000',true,'bafu'),
 ('flow','80700000-0000-4000-8000-000000000103','01.00.000',true,'bafu');

update private.portal_display_rollout set mode='display';
select ok('security_barrier=true'=any((select reloptions from pg_class where oid='private.display_request_visible_settings_v1'::regclass)::text[]),'scope view retains its security barrier');
select ok(not has_table_privilege('anon','private.display_request_visible_settings_v1','select'),'anonymous role cannot read the scope bridge');
select ok(not has_table_privilege('authenticated','private.display_request_visible_settings_v1','select'),'authenticated role cannot read the scope bridge');
select is((select proconfig from pg_proc where oid='api.portal_navigation_v2(text[],text,text,jsonb,text,text,text,integer)'::regprocedure),array['search_path=""','statement_timeout=8s']::text[],'navigation keeps its public budget');
select is((select proconfig from pg_proc where oid='api.portal_facets_v4(text[],text,text,jsonb)'::regprocedure),array['search_path=""','statement_timeout=8s']::text[],'facets keeps its public budget');

create function pg_temp.brand_counts(page jsonb) returns jsonb language sql immutable as $$
 select coalesce(jsonb_object_agg(v->>'value',v->'count'),'{}'::jsonb)
 from jsonb_array_elements(page->'groups') g cross join lateral jsonb_array_elements(g->'values') v
 where g->>'id'='brand'
$$;
grant execute on function pg_temp.brand_counts(jsonb) to anon;
select set_config('portal.display_brands','bafu',true);
select set_config('portal.display_filter_brand','bafu',true);
select set_config('portal.display_global','false',true);
set local role anon;
set local plan_cache_mode='force_generic_plan';
create temp table scope_results(value jsonb);
prepare portal829_facets(text[]) as insert into scope_results select pg_temp.brand_counts(api.portal_facets_v4($1,'all','','{}'));
prepare portal829_nav(text[]) as insert into scope_results select api.portal_navigation_v2($1,'all','','{}','classification')->'totals';
-- The identical prepared statements execute repeatedly under different request scopes.
execute portal829_facets(array['tiangong_lca']);
select is((select value from scope_results),' {"tiangong_lca":1}'::jsonb,'prepared facets admits the requested exact brand');
truncate scope_results;
execute portal829_facets(array['bafu']);
select is((select value from scope_results),' {"bafu":2}'::jsonb,'same prepared facets reads the next brand scope');
truncate scope_results;
execute portal829_facets(array['bafu','tiangong_lca']);
select is((select value from scope_results),' {"bafu":2,"tiangong_lca":1}'::jsonb,'prepared facets can broaden only to its explicit scope');
truncate scope_results;
execute portal829_facets(array['worldsteel']);
select is((select value from scope_results),'{}'::jsonb,'prepared facets does not retain prior matches');
truncate scope_results;
execute portal829_nav(array['tiangong_lca']);
select is((select value from scope_results),'{"process":1,"flow":0}'::jsonb,'prepared navigation counts the exact first scope');
truncate scope_results;
execute portal829_nav(array['bafu']);
select is((select value from scope_results),'{"process":1,"flow":1}'::jsonb,'prepared navigation refreshes the scope');
truncate scope_results;
execute portal829_nav(array['worldsteel']);
select is((select value from scope_results),'{"process":0,"flow":0}'::jsonb,'prepared navigation does not retain earlier totals');

select is(jsonb_build_object(
 'tiangong',pg_temp.brand_counts(api.portal_facets_v4(array['tiangong_lca'],'all','','{}')),
 'bafu',pg_temp.brand_counts(api.portal_facets_v4(array['bafu'],'all','','{}')),
 'empty',pg_temp.brand_counts(api.portal_facets_v4(array['worldsteel'],'all','','{}'))),
 '{"tiangong":{"tiangong_lca":1},"bafu":{"bafu":2},"empty":{}}'::jsonb,
 'multiple differently scoped RPCs in one SQL statement remain isolated');
select is(jsonb_build_object(
 'tiangong',api.portal_navigation_v2(array['tiangong_lca'],'all','','{}','classification')->'totals',
 'bafu',api.portal_navigation_v2(array['bafu'],'all','','{}','classification')->'totals'),
 '{"tiangong":{"process":1,"flow":0},"bafu":{"process":1,"flow":1}}'::jsonb,
 'multiple navigation RPCs in one statement use their own scope');
select is(pg_temp.brand_counts(api.portal_facets_v4(array['tiangong_lca'],'all','','{"brand":"bafu"}')),'{}'::jsonb,'brand filter cannot expand the deployment scope');
select is(pg_temp.brand_counts(api.portal_facets_v4(array['bafu','tiangong_lca'],'all','','{"brand":"bafu"}')),'{"bafu":2}'::jsonb,'brand filter narrows an allowed multi-brand scope');
select is(current_setting('portal.display_brands',true),'bafu','successful calls restore the outer brand setting');
select is(current_setting('portal.display_filter_brand',true),'bafu','successful calls restore the outer brand filter');
select is(current_setting('portal.display_global',true),'false','successful calls restore the outer global setting');
select throws_ok($$select api.portal_facets_v4(array['tiangong_lca'],'invalid','','{}')$$,'22023','invalid portal request','invalid kind fails after request scope entry');
select is(current_setting('portal.display_brands',true),'bafu','failed facets call does not leak its scope');
select throws_ok($$select api.portal_navigation_v2(array['tiangong_lca'],'all','','{}','classification','invalid-node')$$,'22023','invalid portal request','invalid navigation parent fails closed');
select is(current_setting('portal.display_brands',true),'bafu','failed navigation does not leak scope');
select is(pg_temp.brand_counts(api.portal_facets_v4(array['tiangong_lca'],'all','','{}')),'{"tiangong_lca":1}'::jsonb,'next successful request survives failed-scope rollback');
deallocate portal829_facets;
deallocate portal829_nav;
set local plan_cache_mode='auto';
reset role;
-- Private global support reads preserve their existing semantics too.
select set_config('portal.display_global','true',true);
select set_config('portal.display_filter_brand','',true);
set local role portal_display_executor;
select is((select count(*)::integer from private.display_request_visible_settings_v1),3,'global private support sees the exact visible settings');
reset role;
set local role anon;
select is(pg_temp.brand_counts(api.portal_facets_v4(array['tiangong_lca'],'all','','{}')),'{"tiangong_lca":1}'::jsonb,'public RPC overrides an outer global-support scope');
select is(current_setting('portal.display_global',true),'true','public RPC restores the outer global-support setting');
reset role;
set local role portal_display_executor;
set local plan_cache_mode='force_generic_plan';
select set_config('portal.display_global','false',true);
select set_config('portal.display_brands','tiangong_lca',true);
select is((select count(*)::integer from private.display_request_visible_settings_v1),1,'narrow private support scope follows changed GUCs');
select set_config('portal.display_brands','worldsteel',true);
select is((select count(*)::integer from private.display_request_visible_settings_v1),0,'empty private support scope does not retain prior matches');
set local plan_cache_mode='auto';
reset role;
alter view private.display_request_visible_settings_v1 set (security_barrier=false);
set local role anon;
select throws_ok($$select api.portal_facets_v4(array['tiangong_lca'],'all','','{}')$$,'P0001','portal catalog unavailable','integrity assertion refuses security-barrier drift');
reset role;
alter view private.display_request_visible_settings_v1 set (security_barrier=true);
select lives_ok($$select private.portal_display_assert_contract_v1()$$,'restored view passes the unchanged manifest guard');
select * from finish();
rollback;
