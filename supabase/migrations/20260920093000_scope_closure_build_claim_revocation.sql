-- Database #661: admission checks belong to enqueue and payload mutation, not
-- to lease, heartbeat, or terminal status transitions. A certificate can be
-- revoked after enqueue; the Worker must claim that job and record the failed
-- binding instead of leaving a permanently unclaimable queue head.
drop trigger if exists worker_jobs_scope_closure_build_admission
  on private.worker_jobs;
create trigger worker_jobs_scope_closure_build_admission
before insert or update of payload_json on private.worker_jobs
for each row execute function private.lcia_scope_closure_build_admission_guard();

comment on trigger worker_jobs_scope_closure_build_admission on private.worker_jobs is
  'Reject unavailable closure certificates at package-build enqueue or payload mutation; status-only lease and terminal transitions remain claimable for fail-closed Worker handling.';
