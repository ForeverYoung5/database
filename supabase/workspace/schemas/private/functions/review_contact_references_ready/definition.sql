CREATE OR REPLACE FUNCTION "private"."review_contact_references_ready"("p_json_ordered" "jsonb", "p_self_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_ref record;
  v_table text;
  v_exists boolean;
begin
  if p_json_ordered #>> '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet,@refObjectId}'
       is distinct from p_self_id::text then
    return false;
  end if;

  for v_ref in
    with recursive nodes(value) as (
      select coalesce(
        p_json_ordered #- '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet}',
        '{}'::jsonb
      )
      union all
      select child.value
      from nodes
      cross join lateral (
        select value from jsonb_each(
          case when jsonb_typeof(nodes.value) = 'object' then nodes.value else '{}'::jsonb end
        )
        union all
        select value from jsonb_array_elements(
          case when jsonb_typeof(nodes.value) = 'array' then nodes.value else '[]'::jsonb end
        )
      ) child
    )
    select distinct
      value->>'@type' as ref_type,
      (value->>'@refObjectId')::uuid as ref_id,
      value->>'@version' as ref_version
    from nodes
    where jsonb_typeof(value) = 'object'
      and coalesce(value->>'@refObjectId', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and nullif(value->>'@version', '') is not null
      and value->>'@type' in (
        'contact data set', 'source data set', 'unit group data set',
        'flow property data set', 'flow data set', 'process data set',
        'lifeCycleModel data set'
      )
  loop
    v_table := case v_ref.ref_type
      when 'contact data set' then 'contacts'
      when 'source data set' then 'sources'
      when 'unit group data set' then 'unitgroups'
      when 'flow property data set' then 'flowproperties'
      when 'flow data set' then 'flows'
      when 'process data set' then 'processes'
      when 'lifeCycleModel data set' then 'lifecyclemodels'
    end;

    execute format(
      'select exists(select 1 from public.%I where id = $1 and version = $2 and state_code = 100)',
      v_table
    ) into v_exists using v_ref.ref_id, v_ref.ref_version;

    if not coalesce(v_exists, false) then
      return false;
    end if;
  end loop;

  return true;
end;
$_$;

ALTER FUNCTION "private"."review_contact_references_ready"("p_json_ordered" "jsonb", "p_self_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."review_contact_references_ready"("p_json_ordered" "jsonb", "p_self_id" "uuid") FROM PUBLIC;
