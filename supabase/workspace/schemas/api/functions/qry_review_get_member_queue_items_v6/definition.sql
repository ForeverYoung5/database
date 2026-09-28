CREATE OR REPLACE FUNCTION "api"."qry_review_get_member_queue_items_v6"("p_status" "text" DEFAULT 'pending'::"text", "p_page" integer DEFAULT 1, "p_page_size" integer DEFAULT 50, "p_sort_by" "text" DEFAULT 'modified_at'::"text", "p_sort_order" "text" DEFAULT 'desc'::"text", "p_display_mode" "text" DEFAULT 'all'::"text", "p_target_table" "text" DEFAULT NULL::"text", "p_query" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "data_id" "uuid", "data_version" "text", "review_state_code" integer, "review_kind" "text", "target_table" "text", "reviewer_id" "jsonb", "json" "jsonb", "deadline" timestamp with time zone, "created_at" timestamp with time zone, "modified_at" timestamp with time zone, "comment_state_code" integer, "comment_json" "jsonb", "comment_created_at" timestamp with time zone, "comment_modified_at" timestamp with time zone, "reviewer_count" integer, "completed_reviewer_count" integer, "approve_opinion_count" integer, "reject_opinion_count" integer, "root_matches_status" boolean, "root_can_read" boolean, "actor_has_rejection_info" boolean, "total_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "api"."qry_review_get_member_queue_items_v6"("p_status" "text", "p_page" integer, "p_page_size" integer, "p_sort_by" "text", "p_sort_order" "text", "p_display_mode" "text", "p_target_table" "text", "p_query" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_review_get_member_queue_items_v6"("p_status" "text", "p_page" integer, "p_page_size" integer, "p_sort_by" "text", "p_sort_order" "text", "p_display_mode" "text", "p_target_table" "text", "p_query" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_review_get_member_queue_items_v6"("p_status" "text", "p_page" integer, "p_page_size" integer, "p_sort_by" "text", "p_sort_order" "text", "p_display_mode" "text", "p_target_table" "text", "p_query" "text") TO "authenticated";

GRANT ALL ON FUNCTION "api"."qry_review_get_member_queue_items_v6"("p_status" "text", "p_page" integer, "p_page_size" integer, "p_sort_by" "text", "p_sort_order" "text", "p_display_mode" "text", "p_target_table" "text", "p_query" "text") TO "api_internal_executor";
