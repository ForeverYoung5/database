CREATE OR REPLACE FUNCTION "private"."dataset_catalog_source_json"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare relation text; source_json jsonb;
begin
  relation := case p_kind when 'process' then 'processes' when 'flow' then 'flows' when 'lifecyclemodel' then 'lifecyclemodels'
    when 'contact' then 'contacts' when 'source' then 'sources' when 'unitgroup' then 'unitgroups' when 'flowproperty' then 'flowproperties' else null end;
  if relation is null then raise exception using errcode='22023',message='unsupported source kind'; end if;
  execute pg_catalog.format('select json from public.%I where id=$1 and version=$2::character(9)',relation)
    into source_json using p_id,p_version;
  return source_json;
end;
$_$;

ALTER FUNCTION "private"."dataset_catalog_source_json"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_catalog_source_json"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;
