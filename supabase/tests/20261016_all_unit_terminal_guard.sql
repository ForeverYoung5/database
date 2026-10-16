begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into private.lca_network_snapshots(id,scope,status) values ('84600000-0000-4000-8000-000000000001','full_library','ready');
create temporary table terminal_guard_results(label text primary key, value jsonb);
create function pg_temp.enqueue_terminal_guard() returns jsonb language sql as $$
  select api.svc_lca_cached_job_enqueue('full_library','84600000-0000-4000-8000-000000000001',
    'issue846-terminal','{}','lca.solve_all_unit',gen_random_uuid(),'{}','lca.solve_all_unit.request.v1',
    '84600000-0000-4000-8000-000000000002','issue846-terminal','issue846');
$$;
insert into terminal_guard_results values ('initial',pg_temp.enqueue_terminal_guard());
select is((select value->>'mode' from terminal_guard_results), 'queued', 'first request queues');
select is(pg_temp.enqueue_terminal_guard()->>'mode', 'in_progress', 'active result request is reused');
update private.worker_jobs set status='failed', retryable=null, error_code='artifact_too_large'
where id=(select (value->>'worker_job_id')::uuid from terminal_guard_results);
select is(pg_temp.enqueue_terminal_guard()->>'code','LCA_REQUEST_TERMINAL','NULL retryability does not reopen terminal job');
select ok(bool_and(pg_temp.enqueue_terminal_guard()->>'code'='LCA_REQUEST_TERMINAL'),'twenty polls preserve failure') from generate_series(1,20);
select is((select count(*) from private.worker_jobs where idempotency_key='issue846-terminal'),1::bigint,'no successor jobs');
select is(pg_temp.enqueue_terminal_guard()->>'error_code','artifact_too_large','original reason is retained');
update private.worker_jobs set retryable=true where idempotency_key='issue846-terminal';
select is(pg_temp.enqueue_terminal_guard()->>'code','LCA_REQUEST_TERMINAL','retryable true still requires explicit retry');
update private.worker_jobs set retryable=false where idempotency_key='issue846-terminal';
select is(pg_temp.enqueue_terminal_guard()->>'code','WORKER_REQUEST_NON_RETRYABLE_FAILURE','known permanent error preserves legacy code');
update private.worker_jobs set status='cancelled' where idempotency_key='issue846-terminal';
select is(pg_temp.enqueue_terminal_guard()->>'code','LCA_REQUEST_TERMINAL','cancelled job remains terminal');
update private.worker_jobs set status='blocked', blocker_codes=array['artifact_too_large'], resolution_scope='operator' where idempotency_key='issue846-terminal';
select is(pg_temp.enqueue_terminal_guard()->>'code','LCA_REQUEST_TERMINAL','blocked job is not recreated');
select ok((private.worker_retry_job((select (value->>'worker_job_id')::uuid from terminal_guard_results))->>'ok')::boolean,'explicit service retry reuses canonical job');
select is(pg_temp.enqueue_terminal_guard()->>'mode','in_progress','poll observes explicit retry');
select is((select count(*) from private.worker_jobs where idempotency_key='issue846-terminal'),1::bigint,'explicit retry preserves identity');
update private.worker_jobs set status='completed' where idempotency_key='issue846-terminal';
select is(pg_temp.enqueue_terminal_guard()->>'code','LCA_REQUEST_TERMINAL','missing result after completion is not recomputed implicitly');
select ok(not has_function_privilege('authenticated','api.svc_lca_cached_job_enqueue(text,uuid,text,jsonb,text,uuid,jsonb,text,uuid,text,text)','execute'),'enqueue remains service only');
select is(pg_temp.enqueue_terminal_guard()->>'next_action','inspect_missing_result','completed job requires result investigation, not unsupported retry');
update private.lca_result_cache set status='failed',worker_job_id=null,error_code='retained_failure' where request_key='issue846-terminal';
select is(pg_temp.enqueue_terminal_guard()->>'code','LCA_REQUEST_TERMINAL','orphan failed cache never creates a successor');
select is(pg_temp.enqueue_terminal_guard()->>'error_code','retained_failure','orphan failure reason remains available');
select is((select count(*) from private.worker_jobs where idempotency_key='issue846-terminal'),1::bigint,'orphan failure polling preserves job count');
select * from finish();
rollback;
