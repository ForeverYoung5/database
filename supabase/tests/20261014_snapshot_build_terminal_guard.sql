begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

create temporary table snapshot_guard_results(label text primary key, value jsonb);
create function pg_temp.enqueue_snapshot_guard() returns jsonb language sql as $$
  select api.svc_lca_snapshot_build_enqueue('full_library', '{}'::jsonb,
    '84200000-0000-4000-8000-000000000001', 'issue842-terminal', gen_random_uuid(), gen_random_uuid(), '{}');
$$;
insert into snapshot_guard_results values ('initial', pg_temp.enqueue_snapshot_guard());
select is((select value->>'mode' from snapshot_guard_results where label='initial'), 'queued', 'initial request enqueues');
select is(pg_temp.enqueue_snapshot_guard()->>'mode', 'in_progress', 'active request is reused');

update private.worker_jobs set status='failed', retryable=null
where id=(select (value->>'worker_job_id')::uuid from snapshot_guard_results where label='initial');
select is(pg_temp.enqueue_snapshot_guard()->>'code', 'SNAPSHOT_BUILD_FAILED', 'unclassified failure terminates automatic rebuilding');
select ok(bool_and(pg_temp.enqueue_snapshot_guard()->>'code'='SNAPSHOT_BUILD_FAILED'), 'repeated polls preserve failure') from generate_series(1,20);
select is((select count(*) from private.worker_jobs where concurrency_key='lca.build_snapshot:full_library:issue842-terminal'), 1::bigint, 'polls create no replacement jobs');
select is((select count(*) from private.lca_network_snapshots where created_by='84200000-0000-4000-8000-000000000001'), 1::bigint, 'polls create no replacement drafts');
update private.worker_jobs set retryable=true where concurrency_key='lca.build_snapshot:full_library:issue842-terminal';
select is(pg_temp.enqueue_snapshot_guard()->>'code', 'SNAPSHOT_BUILD_FAILED', 'retryable failure still requires explicit retry intent');
update private.worker_jobs set retryable=false where concurrency_key='lca.build_snapshot:full_library:issue842-terminal';
select is(pg_temp.enqueue_snapshot_guard()->>'code', 'SNAPSHOT_BUILD_FAILED', 'nonretryable failure is preserved');
update private.worker_jobs set status='cancelled' where concurrency_key='lca.build_snapshot:full_library:issue842-terminal';
select is(pg_temp.enqueue_snapshot_guard()->>'code', 'SNAPSHOT_BUILD_FAILED', 'cancelled work is not restarted by polling');
update private.worker_jobs set status='blocked', blocker_codes=array['artifact_too_large'], resolution_scope='operator' where concurrency_key='lca.build_snapshot:full_library:issue842-terminal';
select is(pg_temp.enqueue_snapshot_guard()->>'code', 'SNAPSHOT_BUILD_BLOCKED', 'blocked work is not advertised as queued');

select ok((private.worker_retry_job((select (value->>'worker_job_id')::uuid from snapshot_guard_results where label='initial'))->>'ok')::boolean, 'existing explicit service retry recovers same job');
select is(pg_temp.enqueue_snapshot_guard()->>'mode', 'in_progress', 'polling observes explicitly retried work');
select is((select count(*) from private.worker_jobs where concurrency_key='lca.build_snapshot:full_library:issue842-terminal'), 1::bigint, 'explicit retry preserves canonical identity');
update private.worker_jobs set status='completed' where concurrency_key='lca.build_snapshot:full_library:issue842-terminal';
select is(pg_temp.enqueue_snapshot_guard()->>'mode', 'queued', 'successful previous work does not block a later source refresh');
select ok(not has_function_privilege('authenticated','api.svc_lca_snapshot_build_enqueue(text,jsonb,uuid,text,uuid,uuid,jsonb,text)','EXECUTE'), 'browser cannot bypass service enqueue');
select * from finish();
rollback;
