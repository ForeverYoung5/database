-- Database #751: preserve reviewer decisions after finalization and expose
-- permission-scoped rejection details to the review workspaces.

alter table private.comments
  add column if not exists submitted_decision text,
  add column if not exists submitted_decision_at timestamptz;

alter table private.comments
  add constraint comments_submitted_decision_check
  check (submitted_decision is null or submitted_decision in ('approve', 'reject'));

comment on column private.comments.submitted_decision is
  'The reviewer latest submitted decision. Draft state clears it; review finalization and reviewer revocation preserve it.';
comment on column private.comments.submitted_decision_at is
  'The timestamp of the reviewer latest submitted decision.';

create or replace function private.comments_sync_submitted_decision_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state_code = 1 then
    new.submitted_decision := 'approve';
    new.submitted_decision_at := pg_catalog.now();
  elsif new.state_code = -3 then
    new.submitted_decision := 'reject';
    new.submitted_decision_at := pg_catalog.now();
  elsif new.state_code = 0 then
    new.submitted_decision := null;
    new.submitted_decision_at := null;
  elsif tg_op = 'UPDATE' then
    new.submitted_decision := old.submitted_decision;
    new.submitted_decision_at := old.submitted_decision_at;
  end if;
  return new;
end;
$$;

alter function private.comments_sync_submitted_decision_v1() owner to postgres;
revoke all on function private.comments_sync_submitted_decision_v1() from public, anon, authenticated, service_role;

drop trigger if exists comments_sync_submitted_decision_v1 on private.comments;
create trigger comments_sync_submitted_decision_v1
before insert or update of state_code on private.comments
for each row execute function private.comments_sync_submitted_decision_v1();

-- Simple-review JSON records the decision explicitly, so it is authoritative.
update private.comments as comment_row
set submitted_decision = comment_row.json::jsonb->>'decision',
    submitted_decision_at = comment_row.modified_at
where comment_row.json::jsonb->>'decision' in ('approve', 'reject');

-- Active complex-review rows can be reconstructed directly from their opinion state.
update private.comments as comment_row
set submitted_decision = case comment_row.state_code when 1 then 'approve' else 'reject' end,
    submitted_decision_at = comment_row.modified_at
where comment_row.submitted_decision is null
  and comment_row.state_code in (1, -3);

-- Terminal complex-review rows have overwritten state codes. Backfill only when
-- the latest reviewer event is an unambiguous submitted opinion. A later draft
-- intentionally leaves the decision null.
with reviewer_events as (
  select
    comment_row.review_id,
    comment_row.reviewer_id,
    log_entry.value,
    log_entry.ordinality,
    pg_catalog.row_number() over (
      partition by comment_row.review_id, comment_row.reviewer_id
      order by log_entry.ordinality desc
    ) as event_rank
  from private.comments as comment_row
  join private.reviews as review_row on review_row.id = comment_row.review_id
  cross join lateral pg_catalog.jsonb_array_elements(
    api.cmd_review_json_array(review_row.json->'logs')
  ) with ordinality as log_entry(value, ordinality)
  where comment_row.submitted_decision is null
    and log_entry.value->>'action' in (
      'submit_comments',
      'reviewer_rejected',
      'simple_reviewer_approved',
      'simple_reviewer_rejected',
      'submit_comments_temporary'
    )
    and coalesce(
      nullif(log_entry.value->>'reviewer_id', '')::uuid,
      nullif(log_entry.value->'user'->>'id', '')::uuid
    ) = comment_row.reviewer_id
), latest_events as (
  select * from reviewer_events where event_rank = 1
)
update private.comments as comment_row
set submitted_decision = case
      when latest_events.value->>'action' in ('reviewer_rejected', 'simple_reviewer_rejected')
        then 'reject'
      else 'approve'
    end,
    submitted_decision_at = coalesce(
      nullif(latest_events.value->>'time', '')::timestamptz,
      comment_row.modified_at
    )
from latest_events
where comment_row.review_id = latest_events.review_id
  and comment_row.reviewer_id = latest_events.reviewer_id
  and latest_events.value->>'action' <> 'submit_comments_temporary';

create or replace function private.review_rejection_reason_v1(p_payload jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_comment jsonb;
begin
  if nullif(pg_catalog.btrim(p_payload->>'reason'), '') is not null then
    return pg_catalog.btrim(p_payload->>'reason');
  end if;
  v_comment := p_payload->'comment';
  if pg_catalog.jsonb_typeof(v_comment) = 'object' then
    return nullif(pg_catalog.btrim(v_comment->>'message'), '');
  end if;
  if pg_catalog.jsonb_typeof(v_comment) = 'string' then
    begin
      return nullif(pg_catalog.btrim((v_comment #>> '{}')::jsonb->>'message'), '');
    exception when others then
      return null;
    end;
  end if;
  return null;
end;
$$;

alter function private.review_rejection_reason_v1(jsonb) owner to postgres;
revoke all on function private.review_rejection_reason_v1(jsonb) from public, anon, authenticated, service_role;

create or replace function api.qry_review_get_rejection_details_v1(p_review_id uuid)
returns table (
  source text,
  actor_id uuid,
  reason text,
  submitted_at timestamptz,
  reviewer_status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_is_admin boolean := api.cmd_review_is_review_admin(v_actor);
  v_is_member boolean := api.cmd_review_is_review_member(v_actor);
begin
  if v_actor is null or not (v_is_admin or v_is_member) then
    return;
  end if;
  if not api.policy_review_can_read(p_review_id, v_actor) then
    return;
  end if;

  if v_is_admin then
    return query
    select
      'review-admin'::text,
      nullif(admin_log.value->'user'->>'id', '')::uuid,
      private.review_rejection_reason_v1(review_row.json),
      nullif(admin_log.value->>'time', '')::timestamptz,
      null::text
    from private.reviews as review_row
    left join lateral (
      select log_entry.value
      from pg_catalog.jsonb_array_elements(
        api.cmd_review_json_array(review_row.json->'logs')
      ) with ordinality as log_entry(value, ordinality)
      where log_entry.value->>'action' = 'rejected'
      order by log_entry.ordinality desc
      limit 1
    ) as admin_log on true
    where review_row.id = p_review_id
      and review_row.state_code = -1
      and private.review_rejection_reason_v1(review_row.json) is not null;
  end if;

  return query
  select
    'reviewer'::text,
    comment_row.reviewer_id,
    private.review_rejection_reason_v1(comment_row.json::jsonb),
    comment_row.submitted_decision_at,
    case when comment_row.state_code = -2 then 'revoked' else 'active' end
  from private.comments as comment_row
  where comment_row.review_id = p_review_id
    and comment_row.submitted_decision = 'reject'
    and private.review_rejection_reason_v1(comment_row.json::jsonb) is not null
    and (v_is_admin or comment_row.reviewer_id = v_actor)
  order by comment_row.submitted_decision_at, comment_row.reviewer_id;
end;
$$;

alter function api.qry_review_get_rejection_details_v1(uuid) owner to postgres;
revoke all on function api.qry_review_get_rejection_details_v1(uuid) from public, anon, service_role;
grant execute on function api.qry_review_get_rejection_details_v1(uuid)
  to authenticated, api_internal_executor;

create or replace function api.qry_review_get_admin_queue_items_v6(
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_sort_by text default 'modified_at',
  p_sort_order text default 'desc',
  p_display_mode text default 'all',
  p_target_table text default null,
  p_query text default null
)
returns table (
  id uuid, data_id uuid, data_version text, state_code integer, review_kind text,
  target_table text, reviewer_id jsonb, "json" jsonb, deadline timestamptz,
  created_at timestamptz, modified_at timestamptz, comment_state_codes jsonb,
  reviewer_count integer, completed_reviewer_count integer,
  approve_opinion_count integer, reject_opinion_count integer,
  root_matches_status boolean, root_can_read boolean,
  has_rejection_info boolean, total_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    queue_row.id, queue_row.data_id, queue_row.data_version, queue_row.state_code,
    queue_row.review_kind, queue_row.target_table, queue_row.reviewer_id,
    queue_row.json, queue_row.deadline, queue_row.created_at, queue_row.modified_at,
    queue_row.comment_state_codes, queue_row.reviewer_count,
    queue_row.completed_reviewer_count, queue_row.approve_opinion_count,
    queue_row.reject_opinion_count, queue_row.root_matches_status,
    queue_row.root_can_read,
    (
      (queue_row.state_code = -1 and private.review_rejection_reason_v1(queue_row.json) is not null)
      or exists (
        select 1 from private.comments as comment_row
        where comment_row.review_id = queue_row.id
          and comment_row.submitted_decision = 'reject'
          and private.review_rejection_reason_v1(comment_row.json::jsonb) is not null
      )
    ) as has_rejection_info,
    queue_row.total_count
  from api.qry_review_get_admin_queue_items_v5(
    p_status, p_page, p_page_size, p_sort_by, p_sort_order,
    p_display_mode, p_target_table, p_query
  ) as queue_row
$$;

alter function api.qry_review_get_admin_queue_items_v6(text, integer, integer, text, text, text, text, text) owner to postgres;
revoke all on function api.qry_review_get_admin_queue_items_v6(text, integer, integer, text, text, text, text, text) from public, anon, service_role;
grant execute on function api.qry_review_get_admin_queue_items_v6(text, integer, integer, text, text, text, text, text) to authenticated, api_internal_executor;

create or replace function api.qry_review_get_member_queue_items_v6(
  p_status text default 'pending',
  p_page integer default 1,
  p_page_size integer default 50,
  p_sort_by text default 'modified_at',
  p_sort_order text default 'desc',
  p_display_mode text default 'all',
  p_target_table text default null,
  p_query text default null
)
returns table (
  id uuid, data_id uuid, data_version text, review_state_code integer,
  review_kind text, target_table text, reviewer_id jsonb, "json" jsonb,
  deadline timestamptz, created_at timestamptz, modified_at timestamptz,
  comment_state_code integer, comment_json jsonb,
  comment_created_at timestamptz, comment_modified_at timestamptz,
  reviewer_count integer, completed_reviewer_count integer,
  approve_opinion_count integer, reject_opinion_count integer,
  root_matches_status boolean, root_can_read boolean,
  actor_has_rejection_info boolean, total_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    queue_row.id, queue_row.data_id, queue_row.data_version,
    queue_row.review_state_code, queue_row.review_kind, queue_row.target_table,
    queue_row.reviewer_id, queue_row.json, queue_row.deadline,
    queue_row.created_at, queue_row.modified_at, queue_row.comment_state_code,
    queue_row.comment_json, queue_row.comment_created_at,
    queue_row.comment_modified_at, queue_row.reviewer_count,
    queue_row.completed_reviewer_count, queue_row.approve_opinion_count,
    queue_row.reject_opinion_count, queue_row.root_matches_status,
    queue_row.root_can_read,
    exists (
      select 1 from private.comments as comment_row
      where comment_row.review_id = queue_row.id
        and comment_row.reviewer_id = auth.uid()
        and comment_row.submitted_decision = 'reject'
        and private.review_rejection_reason_v1(comment_row.json::jsonb) is not null
    ) as actor_has_rejection_info,
    queue_row.total_count
  from api.qry_review_get_member_queue_items_v5(
    p_status, p_page, p_page_size, p_sort_by, p_sort_order,
    p_display_mode, p_target_table, p_query
  ) as queue_row
$$;

alter function api.qry_review_get_member_queue_items_v6(text, integer, integer, text, text, text, text, text) owner to postgres;
revoke all on function api.qry_review_get_member_queue_items_v6(text, integer, integer, text, text, text, text, text) from public, anon, service_role;
grant execute on function api.qry_review_get_member_queue_items_v6(text, integer, integer, text, text, text, text, text) to authenticated, api_internal_executor;

comment on function api.qry_review_get_rejection_details_v1(uuid) is
  'Returns rejection details with role-scoped visibility: review admins see admin and reviewer reasons; reviewers see only their own reason.';
comment on function api.qry_review_get_admin_queue_items_v6(text, integer, integer, text, text, text, text, text) is
  'V5 review-admin workspace queue plus a non-counting rejection-information availability flag.';
comment on function api.qry_review_get_member_queue_items_v6(text, integer, integer, text, text, text, text, text) is
  'V5 reviewer workspace queue plus an actor-scoped rejection-information availability flag.';

insert into private.api_capability_grants (
  routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role
)
values
  ('api.qry_review_get_rejection_details_v1(uuid)', 'NX-REV-01', false, true, false),
  ('api.qry_review_get_admin_queue_items_v6(text, integer, integer, text, text, text, text, text)', 'NX-REV-01', false, true, false),
  ('api.qry_review_get_member_queue_items_v6(text, integer, integer, text, text, text, text, text)', 'NX-REV-01', false, true, false)
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;
