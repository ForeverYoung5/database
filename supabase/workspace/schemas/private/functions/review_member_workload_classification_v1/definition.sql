CREATE OR REPLACE FUNCTION "private"."review_member_workload_classification_v1"("p_reviewer_id" "uuid") RETURNS TABLE("review_id" "uuid", "reviewer_id" "uuid", "workload_status" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "private"."review_member_workload_classification_v1"("p_reviewer_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."review_member_workload_classification_v1"("p_reviewer_id" "uuid") FROM PUBLIC;
