begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;

select plan(4);

select is(
  (
    select submitted_decision
    from private.comments
    where review_id = '59628100-0000-0000-0000-000000000001'
  ),
  'reject',
  'upgrade backfills the retained legacy reviewer rejection'
);

select is(
  (
    select submitted_decision_at
    from private.comments
    where review_id = '59628100-0000-0000-0000-000000000001'
  ),
  '2026-09-28T12:00:00Z'::timestamptz,
  'upgrade preserves the legacy comment timestamp as submission time'
);

select ok(
  pg_catalog.current_setting('app.review_legacy_migration', true) is distinct from 'on',
  'upgrade leaves the legacy migration bypass disabled'
);

select throws_ok(
  $test$
    update private.comments
    set json = '{"comment":{"message":"Mutation must stay blocked"}}'
    where review_id = '59628100-0000-0000-0000-000000000001'
  $test$,
  '55000',
  'LEGACY_REVIEW_READ_ONLY',
  'legacy review comments remain read-only after the upgrade'
);

select * from finish();
rollback;
