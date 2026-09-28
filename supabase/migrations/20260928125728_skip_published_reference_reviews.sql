CREATE OR REPLACE FUNCTION "private"."review_get_or_create_reference_v1"("p_target_table" "text", "p_target_row" "jsonb", "p_checksum" "text", "p_actor" "uuid") RETURNS "private"."reviews"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_reference private.reviews%rowtype;
  v_owner_id uuid := nullif(p_target_row->>'user_id', '')::uuid;
  v_team_id uuid := nullif(p_target_row->>'team_id', '')::uuid;
  v_state integer := coalesce((p_target_row->>'state_code')::integer, 0);
begin
  if v_state >= 100 then
    return null;
  end if;

  if v_owner_id is null then
    raise exception using
      errcode = '23502',
      message = 'REFERENCE_OWNER_UNRESOLVED';
  end if;


  select reference_row.*
  into v_reference
  from private.reviews as reference_row
  where reference_row.review_kind = 'reference'
    and reference_row.target_table = p_target_table
    and reference_row.data_id = (p_target_row->>'id')::uuid
    and btrim(reference_row.data_version::text) = p_target_row->>'version'
    and reference_row.submitted_revision_checksum = p_checksum
    and reference_row.state_code in (0, 1, 2)
  order by reference_row.state_code desc, reference_row.created_at
  limit 1
  for update;

  if found then
    return v_reference;
  end if;

  begin
    insert into private.reviews (
      id,
      data_id,
      data_version,
      state_code,
      reviewer_id,
      json,
      review_kind,
      target_table,
      submitted_revision_checksum,
      approved_revision_checksum,
      target_owner_id,
      target_team_id
    )
    values (
      gen_random_uuid(),
      (p_target_row->>'id')::uuid,
      p_target_row->>'version',
      0,
      '[]'::jsonb,
      private.review_build_json_v1(
        p_target_table,
        p_target_row,
        v_owner_id,
        'submit_reference_review',
        p_actor
      ),
      'reference',
      p_target_table,
      p_checksum,
      null,
      v_owner_id,
      v_team_id
    )
    returning * into v_reference;
  exception
    when unique_violation then
      select reference_row.*
      into strict v_reference
      from private.reviews as reference_row
      where reference_row.review_kind = 'reference'
        and reference_row.target_table = p_target_table
        and reference_row.data_id = (p_target_row->>'id')::uuid
        and btrim(reference_row.data_version::text) = p_target_row->>'version'
        and reference_row.submitted_revision_checksum = p_checksum
        and reference_row.state_code in (0, 1, 2)
      order by reference_row.state_code desc, reference_row.created_at
      limit 1
      for update;
  end;

  return v_reference;
end;
$$;

ALTER FUNCTION "private"."review_get_or_create_reference_v1"("p_target_table" "text", "p_target_row" "jsonb", "p_checksum" "text", "p_actor" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."review_get_or_create_reference_v1"("p_target_table" "text", "p_target_row" "jsonb", "p_checksum" "text", "p_actor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."review_get_or_create_reference_v1"("p_target_table" "text", "p_target_row" "jsonb", "p_checksum" "text", "p_actor" "uuid") TO "api_internal_executor";

CREATE OR REPLACE FUNCTION "private"."review_derive_current_references_v1"("p_root_review_ids" "uuid"[]) RETURNS TABLE("root_review_id" "uuid", "reference_review_id" "uuid", "target_table" "text", "data_id" "uuid", "data_version" "text", "submitted_revision_checksum" "text", "state_code" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1
    from private.review_resolve_current_reference_targets_v1(
      p_root_review_ids
    ) as target
    join private.reviews as root_review
      on root_review.id = target.root_review_id
      and root_review.state_code in (0, 1)
    where coalesce((
      api.cmd_review_get_dataset_row(
        target.target_table,
        target.data_id,
        target.data_version,
        false
      )->>'state_code'
    )::integer, 0) < 100
      and not exists (
      select 1
      from private.reviews as candidate
      where candidate.review_kind = 'reference'
        and candidate.target_table = target.target_table
        and candidate.data_id = target.data_id
        and pg_catalog.btrim(candidate.data_version::text) = target.data_version
        and candidate.submitted_revision_checksum = target.revision_checksum
        and candidate.state_code in (-1, 0, 1, 2)
    )
  ) then
    raise exception using
      errcode = '55000',
      message = 'MISSING_CURRENT_REFERENCE_REVIEW';
  end if;

  return query
  select
    target.root_review_id,
    reference_review.id,
    target.target_table,
    target.data_id,
    target.data_version,
    reference_review.submitted_revision_checksum,
    reference_review.state_code
  from private.review_resolve_current_reference_targets_v1(
    p_root_review_ids
  ) as target
  join lateral (
    select candidate.*
    from private.reviews as candidate
    where candidate.review_kind = 'reference'
      and candidate.target_table = target.target_table
      and candidate.data_id = target.data_id
      and pg_catalog.btrim(candidate.data_version::text) = target.data_version
      and candidate.submitted_revision_checksum = target.revision_checksum
      and candidate.state_code in (-1, 0, 1, 2)
    order by
      case when candidate.state_code in (0, 1, 2) then 0 else 1 end,
      candidate.modified_at desc,
      candidate.id
    limit 1
  ) as reference_review on true
  where coalesce((
    api.cmd_review_get_dataset_row(
      target.target_table,
      target.data_id,
      target.data_version,
      false
    )->>'state_code'
  )::integer, 0) < 100
  order by target.root_review_id, target.target_table,
    target.data_id, target.data_version;
end;
$$;

ALTER FUNCTION "private"."review_derive_current_references_v1"("p_root_review_ids" "uuid"[]) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."review_derive_current_references_v1"("p_root_review_ids" "uuid"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."review_derive_current_references_v1"("p_root_review_ids" "uuid"[]) TO "api_internal_executor";
