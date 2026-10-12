-- Database #834 / Worker #318: advance admission after canonical LCIA display metadata parsing
-- changes. New requests must not reuse an r4 completed scan's frozen impact
-- axis. Historical requests, certificates, snapshots and artifacts retain
-- their recorded revision and bytes; coordinate rollout with r5-capable Workers.

set lock_timeout = '5s';
set statement_timeout = '120s';

insert into private.lcia_scope_closure_config (
  singleton,
  expected_validator_scanner_fingerprint
)
values (
  true,
  'scope-closure-validator-scanner.v1+cutoff-readiness-r5'
)
on conflict (singleton) do update
set expected_validator_scanner_fingerprint = excluded.expected_validator_scanner_fingerprint,
    updated_at = statement_timestamp();
