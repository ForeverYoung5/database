create extension if not exists pgtap with schema extensions;
set search_path = extensions, public, auth;

select plan(1);

-- Reproduce the retained persistent-Dev shape before the rejection-visibility
-- migration exists. Replication mode is limited to fixture insertion so the
-- legacy review guard remains active for the migration and head assertions.
set session_replication_role = replica;

insert into private.reviews (
  id, data_id, data_version, state_code, reviewer_id, json
)
values (
  '59628100-0000-0000-0000-000000000001',
  '49628100-0000-0000-0000-000000000001',
  '01.00.000',
  1,
  '["19628100-0000-0000-0000-000000000001"]',
  '{"data":{"id":"49628100-0000-0000-0000-000000000001","version":"01.00.000","table":"processes"},"logs":[]}'
);

insert into private.comments (
  review_id, reviewer_id, json, state_code, modified_at
)
values (
  '59628100-0000-0000-0000-000000000001',
  '19628100-0000-0000-0000-000000000001',
  '{"comment":{"message":"Retained legacy rejection"}}',
  -3,
  '2026-09-28T12:00:00Z'::timestamptz
);

reset session_replication_role;

select ok(
  exists (
    select 1
    from private.comments as comment_row
    join private.reviews as review_row on review_row.id = comment_row.review_id
    where comment_row.review_id = '59628100-0000-0000-0000-000000000001'
      and comment_row.state_code = -3
      and review_row.review_kind is null
  ),
  'pre-migration fixture contains a rejected legacy review comment'
);

select * from finish();
