-- Database #759: make Review Member workload counts and administrator
-- drill-down rows share one durable classification contract.

create or replace function private.review_member_workload_classification_v1(
  p_reviewer_id uuid
)
returns table (
  review_id uuid,
  reviewer_id uuid,
  workload_status text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    review_row.id,
    comment_row.reviewer_id,
    case
      when review_row.state_code = 1
        and comment_row.state_code = 0
        and coalesce(review_row.reviewer_id, '[]'::jsonb)
          @> pg_catalog.jsonb_build_array(pg_catalog.to_jsonb(comment_row.reviewer_id::text))
        then 'pending'::text
      when comment_row.submitted_decision is not null then 'reviewed'::text
      else null::text
    end as workload_status
  from private.comments as comment_row
  join private.reviews as review_row on review_row.id = comment_row.review_id
  where comment_row.reviewer_id = p_reviewer_id
    and review_row.review_kind in ('root', 'reference')
    and (
      (
        review_row.state_code = 1
        and comment_row.state_code = 0
        and coalesce(review_row.reviewer_id, '[]'::jsonb)
          @> pg_catalog.jsonb_build_array(pg_catalog.to_jsonb(comment_row.reviewer_id::text))
      )
      or comment_row.submitted_decision is not null
    )
$$;

alter function private.review_member_workload_classification_v1(uuid) owner to postgres;
revoke all on function private.review_member_workload_classification_v1(uuid)
  from public, anon, authenticated, service_role;

create or replace function api.qry_review_get_member_workload(
  p_page integer default 1,
  p_page_size integer default 10,
  p_sort_by text default 'created_at',
  p_sort_order text default 'desc',
  p_role text default null
)
returns table (
  user_id uuid,
  team_id uuid,
  role text,
  email text,
  display_name text,
  pending_count bigint,
  reviewed_count bigint,
  created_at timestamptz,
  modified_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_team_id uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_limit integer := greatest(1, least(coalesce(p_page_size, 10), 100));
  v_offset integer := (greatest(coalesce(p_page, 1), 1) - 1) * v_limit;
  v_order_by text := api.cmd_membership_resolve_member_order_by(p_sort_by, true);
  v_order_dir text := api.cmd_membership_resolve_sort_direction(p_sort_order);
begin
  if v_actor is null or not api.cmd_membership_is_review_admin(v_actor) then
    return;
  end if;

  return query execute pg_catalog.format(
    $sql$
      with members as (
        select
          role_row.user_id,
          role_row.team_id,
          role_row.role::text as role,
          coalesce(user_row.raw_user_meta_data->>'email', '') as email,
          coalesce(
            nullif(user_row.raw_user_meta_data->>'display_name', ''),
            user_row.raw_user_meta_data->>'email',
            '-'
          ) as display_name,
          coalesce(workload.pending_count, 0) as pending_count,
          coalesce(workload.reviewed_count, 0) as reviewed_count,
          role_row.created_at,
          role_row.modified_at
        from private.roles as role_row
        left join private.users as user_row on user_row.id = role_row.user_id
        left join lateral (
          select
            count(*) filter (where item.workload_status = 'pending') as pending_count,
            count(*) filter (where item.workload_status = 'reviewed') as reviewed_count
          from private.review_member_workload_classification_v1(role_row.user_id) as item
        ) as workload on true
        where role_row.team_id = $1
          and role_row.role in ('review-admin', 'review-member')
          and ($4::text is null or role_row.role = $4::text)
      )
      select
        m.user_id,
        m.team_id,
        m.role,
        m.email,
        m.display_name,
        m.pending_count,
        m.reviewed_count,
        m.created_at,
        m.modified_at,
        count(*) over() as total_count
      from members as m
      order by %s %s nulls last, m.user_id asc
      limit $2 offset $3
    $sql$,
    v_order_by,
    v_order_dir
  ) using v_team_id, v_limit, v_offset, p_role;
end;
$$;

alter function api.qry_review_get_member_workload(integer, integer, text, text, text) owner to postgres;
revoke all on function api.qry_review_get_member_workload(integer, integer, text, text, text)
  from public, anon, service_role;
grant execute on function api.qry_review_get_member_workload(integer, integer, text, text, text)
  to authenticated, api_internal_executor;

create or replace function api.qry_review_get_member_workload_items_v1(
  p_reviewer_id uuid,
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
  id uuid,
  data_id uuid,
  data_version text,
  review_state_code integer,
  review_kind text,
  target_table text,
  reviewer_id jsonb,
  "json" jsonb,
  deadline timestamptz,
  created_at timestamptz,
  modified_at timestamptz,
  comment_state_code integer,
  comment_json jsonb,
  comment_created_at timestamptz,
  comment_modified_at timestamptz,
  reviewer_count integer,
  completed_reviewer_count integer,
  approve_opinion_count integer,
  reject_opinion_count integer,
  root_matches_status boolean,
  root_can_read boolean,
  actor_has_rejection_info boolean,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_query text := nullif(pg_catalog.btrim(p_query), '');
  v_limit integer := greatest(1, least(coalesce(p_page_size, 50), 100));
  v_offset integer := (greatest(coalesce(p_page, 1), 1) - 1) * v_limit;
  v_sort_key text := case pg_catalog.lower(coalesce(p_sort_by, ''))
    when 'created_at' then 'created_at'
    when 'createat' then 'created_at'
    when 'deadline' then 'deadline'
    when 'state_code' then 'state_code'
    when 'statecode' then 'state_code'
    when 'comment_modified_at' then 'comment_modified_at'
    when 'commentmodifiedat' then 'comment_modified_at'
    else 'modified_at'
  end;
  v_order_dir text := api.cmd_membership_resolve_sort_direction(p_sort_order);
  v_status text := pg_catalog.lower(coalesce(p_status, 'pending'));
  v_display_mode text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_display_mode, 'all')));
  v_target_table text := nullif(
    pg_catalog.lower(pg_catalog.btrim(coalesce(p_target_table, ''))),
    ''
  );
begin
  if v_actor is null or not api.cmd_membership_is_review_admin(v_actor) then
    return;
  end if;
  if p_reviewer_id is null or not exists (
    select 1
    from private.roles as role_row
    where role_row.user_id = p_reviewer_id
      and role_row.team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and role_row.role in ('review-admin', 'review-member')
  ) then
    return;
  end if;
  if v_status not in ('pending', 'reviewed') then
    return;
  end if;
  if v_display_mode not in ('all', 'model_process', 'other') then
    raise exception using errcode = '22023', message = 'INVALID_REVIEW_DISPLAY_MODE';
  end if;
  if v_target_table is not null and not (
    v_target_table = any(array[
      'contacts', 'sources', 'unitgroups', 'flowproperties', 'flows',
      'processes', 'lifecyclemodels'
    ]::text[])
  ) then
    raise exception using errcode = '22023', message = 'INVALID_REVIEW_TARGET_TABLE';
  end if;
  if pg_catalog.char_length(v_query) > 1000 then
    raise exception using errcode = '22023', message = 'REVIEW_QUERY_TOO_LONG';
  end if;

  return query
  with matches as materialized (
    select * from private.review_search_dataset_versions_v1(v_query, v_target_table)
    where v_query is not null
  ), queue_rows as (
    select
      review_row.id,
      review_row.data_id,
      pg_catalog.btrim(review_row.data_version::text) as data_version,
      review_row.state_code as review_state_code,
      review_row.review_kind,
      review_row.target_table,
      coalesce(review_row.reviewer_id, '[]'::jsonb) as reviewer_id,
      coalesce(review_row.json, '{}'::jsonb) as json,
      review_row.deadline,
      review_row.created_at,
      greatest(review_row.modified_at, reviewer_comment.modified_at) as modified_at,
      reviewer_comment.state_code as comment_state_code,
      coalesce(reviewer_comment.json::jsonb, '{}'::jsonb) as comment_json,
      reviewer_comment.created_at as comment_created_at,
      reviewer_comment.modified_at as comment_modified_at,
      pg_catalog.jsonb_array_length(coalesce(review_row.reviewer_id, '[]'::jsonb))::integer
        as reviewer_count,
      coalesce(review_comments.completed_reviewer_count, 0)::integer
        as completed_reviewer_count,
      coalesce(review_comments.approve_opinion_count, 0)::integer
        as approve_opinion_count,
      coalesce(review_comments.reject_opinion_count, 0)::integer
        as reject_opinion_count,
      true as root_matches_status,
      true as root_can_read,
      reviewer_comment.submitted_decision = 'reject'
        and private.review_rejection_reason_v1(reviewer_comment.json::jsonb) is not null
        as actor_has_rejection_info
    from private.review_member_workload_classification_v1(p_reviewer_id) as workload
    join private.reviews as review_row on review_row.id = workload.review_id
    join private.comments as reviewer_comment
      on reviewer_comment.review_id = workload.review_id
      and reviewer_comment.reviewer_id = workload.reviewer_id
    left join lateral (
      select
        pg_catalog.count(*) filter (
          where comment_row.state_code in (1, -3, 2, -1)
        ) as completed_reviewer_count,
        pg_catalog.count(*) filter (where comment_row.state_code in (1, 2))
          as approve_opinion_count,
        pg_catalog.count(*) filter (where comment_row.state_code in (-3, -1))
          as reject_opinion_count
      from private.comments as comment_row
      where comment_row.review_id = review_row.id
        and coalesce(review_row.reviewer_id, '[]'::jsonb)
          @> pg_catalog.jsonb_build_array(pg_catalog.to_jsonb(comment_row.reviewer_id::text))
        and comment_row.state_code <> -2
    ) as review_comments on true
    where workload.workload_status = v_status
      and api.policy_review_can_read(review_row.id, v_actor)
      and (
        v_display_mode = 'all'
        or (v_display_mode = 'model_process' and review_row.target_table in ('processes', 'lifecyclemodels'))
        or (v_display_mode = 'other' and review_row.target_table not in ('processes', 'lifecyclemodels'))
      )
      and (v_target_table is null or review_row.target_table = v_target_table)
      and (v_query is null or exists (
        select 1 from matches
        where matches.target_table = review_row.target_table
          and matches.data_id = review_row.data_id
          and matches.data_version = review_row.data_version
      ))
  )
  select queue_rows.*, pg_catalog.count(*) over() as total_count
  from queue_rows
  order by
    case when v_sort_key = 'created_at' and v_order_dir = 'asc' then queue_rows.created_at end asc nulls last,
    case when v_sort_key = 'created_at' and v_order_dir = 'desc' then queue_rows.created_at end desc nulls last,
    case when v_sort_key = 'deadline' and v_order_dir = 'asc' then queue_rows.deadline end asc nulls last,
    case when v_sort_key = 'deadline' and v_order_dir = 'desc' then queue_rows.deadline end desc nulls last,
    case when v_sort_key = 'state_code' and v_order_dir = 'asc' then queue_rows.review_state_code end asc nulls last,
    case when v_sort_key = 'state_code' and v_order_dir = 'desc' then queue_rows.review_state_code end desc nulls last,
    case when v_sort_key = 'comment_modified_at' and v_order_dir = 'asc' then queue_rows.comment_modified_at end asc nulls last,
    case when v_sort_key = 'comment_modified_at' and v_order_dir = 'desc' then queue_rows.comment_modified_at end desc nulls last,
    case when v_sort_key = 'modified_at' and v_order_dir = 'asc' then queue_rows.modified_at end asc nulls last,
    case when v_sort_key = 'modified_at' and v_order_dir = 'desc' then queue_rows.modified_at end desc nulls last,
    queue_rows.id
  limit v_limit offset v_offset;
end;
$$;

alter function api.qry_review_get_member_workload_items_v1(uuid, text, integer, integer, text, text, text, text, text)
  owner to postgres;
revoke all on function api.qry_review_get_member_workload_items_v1(uuid, text, integer, integer, text, text, text, text, text)
  from public, anon, service_role;
grant execute on function api.qry_review_get_member_workload_items_v1(uuid, text, integer, integer, text, text, text, text, text)
  to authenticated, api_internal_executor;

comment on function private.review_member_workload_classification_v1(uuid) is
  'Classifies one reviewer workload: current assigned drafts are pending and durable submitted decisions are reviewed.';
comment on function api.qry_review_get_member_workload(integer, integer, text, text, text) is
  'Lists Review team members with pending and reviewed workload counts from the shared workload classification.';
comment on function api.qry_review_get_member_workload_items_v1(uuid, text, integer, integer, text, text, text, text, text) is
  'Review-admin-only paginated drill-down for one reviewer workload, using the same classification as member counts.';

insert into private.api_capability_grants (
  routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role
)
values (
  'api.qry_review_get_member_workload_items_v1(uuid, text, integer, integer, text, text, text, text, text)',
  'NX-REV-01', false, true, false
)
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;
