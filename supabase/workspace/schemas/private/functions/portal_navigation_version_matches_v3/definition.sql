CREATE OR REPLACE FUNCTION "private"."portal_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") RETURNS boolean
    LANGUAGE "sql" STABLE PARALLEL SAFE
    AS $$
  select
    (
      not (p_filters ? 'classificationNodeId')
      or exists (
        select 1
        from private.portal_navigation_membership_v1 as member
        where member.dataset_kind = p_kind
          and member.id = p_id
          and member.version = p_version
          and member.dimension = 'classification'
          and (
            case coalesce(p_filters ->> 'classificationScope', 'subtree')
              when 'direct' then
                member.node_id = p_filters ->> 'classificationNodeId'
                and member.direct
              else member.node_id = p_filters ->> 'classificationNodeId'
            end
          )
      )
    )
    and (
      not (p_filters ? 'geographyNodeId')
      or exists (
        select 1
        from private.portal_navigation_membership_v1 as member
        where member.dataset_kind = p_kind
          and member.id = p_id
          and member.version = p_version
          and member.dimension = 'geography'
          and (
            case coalesce(p_filters ->> 'geographyScope', 'subtree')
              when 'direct' then
                member.node_id = p_filters ->> 'geographyNodeId'
                and member.direct
              else member.node_id = p_filters ->> 'geographyNodeId'
            end
          )
      )
    )
$$;

ALTER FUNCTION "private"."portal_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") FROM PUBLIC;
