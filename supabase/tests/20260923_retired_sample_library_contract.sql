-- Database #707: the superseded sample-library database contract is absent.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select plan(5);

select ok(
  to_regprocedure('api.qry_sample_library_datasets_v1(text,text,text,integer,integer)') is null,
  'manager-only sample-library query has been retired'
);
select ok(
  to_regprocedure('api.cmd_sample_library_publish_processes_v1(jsonb)') is null,
  'unconfirmed Process publication command has been retired'
);
select ok(
  to_regclass('private.sample_library_process_publications') is null
    and to_regclass('private.sample_library_process_publications_published_at_idx') is null
    and to_regprocedure('private.sample_library_process_publications_immutable_v1()') is null,
  'the private publication relation, index and guard have been retired'
);
select is(
  (select count(*) from private.api_capability_grants
   where routine_identity in (
     'api.qry_sample_library_datasets_v1(text, text, text, integer, integer)',
     'api.cmd_sample_library_publish_processes_v1(jsonb)'
   )),
  0::bigint,
  'the two retired RPCs have no capability grants'
);
select ok(
  to_regclass('public.processes') is not null
    and to_regprocedure('api.cmd_result_process_publish_v1(jsonb)') is not null,
  'Process data and the independent Result publication contract remain available'
);

select * from finish();
rollback;
