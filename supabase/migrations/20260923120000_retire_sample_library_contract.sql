-- Database #707: retire the sample-library APIs and the unused Process publication
-- model from #685. The original migration remains in history because Dev applied it.

begin;

-- Serialize against the publication writer and refuse to discard any recorded decision.
lock table private.sample_library_process_publications in access exclusive mode;
do $$
begin
  if exists (select 1 from private.sample_library_process_publications) then
    raise exception using
      errcode = '55000',
      message = 'SAMPLE_LIBRARY_PUBLICATIONS_NOT_EMPTY',
      detail = 'Review and migrate existing publication records before retiring this table.';
  end if;
end;
$$;

delete from private.api_capability_grants
where routine_identity in (
  'api.qry_sample_library_datasets_v1(text, text, text, integer, integer)',
  'api.cmd_sample_library_publish_processes_v1(jsonb)'
);

drop function api.qry_sample_library_datasets_v1(text, text, text, integer, integer);
drop function api.cmd_sample_library_publish_processes_v1(jsonb);
drop table private.sample_library_process_publications;
drop function private.sample_library_process_publications_immutable_v1();

notify pgrst, 'reload schema';

commit;
