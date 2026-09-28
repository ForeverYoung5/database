CREATE OR REPLACE FUNCTION "api"."qry_review_get_rejection_details_v1"("p_review_id" "uuid") RETURNS TABLE("source" "text", "actor_id" "uuid", "reason" "text", "submitted_at" timestamp with time zone, "reviewer_status" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "api"."qry_review_get_rejection_details_v1"("p_review_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_review_get_rejection_details_v1"("p_review_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_review_get_rejection_details_v1"("p_review_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "api"."qry_review_get_rejection_details_v1"("p_review_id" "uuid") TO "api_internal_executor";
