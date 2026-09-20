-- Database #661: status-only Worker claims and terminal writes must not run
-- the certificate admission trigger after an already-enqueued build is revoked.
-- Worker #299 provides the stateful end-to-end revocation/zero-publication proof.
begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private;
select no_plan();

select ok(
  exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'private.worker_jobs'::regclass
      and t.tgname = 'worker_jobs_scope_closure_build_admission'
      and not t.tgisinternal
      and pg_get_triggerdef(t.oid) like '%BEFORE INSERT OR UPDATE OF payload_json%'
      and t.tgfoid = 'private.lcia_scope_closure_build_admission_guard()'::regprocedure
  ),
  'package-build admission still guards inserts and payload mutations'
);

select ok(
  not exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'private.worker_jobs'::regclass
      and t.tgname = 'worker_jobs_scope_closure_build_admission'
      and pg_get_triggerdef(t.oid) like '%UPDATE OF status%'
  ),
  'status-only claim and terminal transitions cannot be poisoned by a revoked certificate'
);

select ok(
  pg_get_functiondef(
    'private.lcia_scope_closure_build_admission_guard()'::regprocedure
  ) like '%closure_certificate_expired_or_unavailable%',
  'the unchanged admission function still rejects unavailable certificate bindings'
);

select * from finish();
rollback;
