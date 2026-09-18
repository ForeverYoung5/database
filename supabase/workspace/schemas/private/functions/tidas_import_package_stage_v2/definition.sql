CREATE OR REPLACE FUNCTION "private"."tidas_import_package_stage_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_offset" integer, "p_entries" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
begin
  perform private.tidas_import_guard_v2(p_worker_job_id,p_lease_token,p_source_artifact_id);
  if p_plan_sha256 is null or p_plan_sha256 !~ '^[0-9a-f]{64}$'
    or p_offset is null or p_offset < 0 or jsonb_typeof(p_entries) is distinct from 'array' then
    raise exception using errcode='22023', message='TIDAS_IMPORT_PACKAGE_CHUNK_INVALID';
  end if;
  if jsonb_array_length(p_entries) < 1 or jsonb_array_length(p_entries) > 1000
    or p_offset::bigint + jsonb_array_length(p_entries) > 100000
    or octet_length(p_entries::text) > 67108864 then
    raise exception using errcode='54000', message='TIDAS_IMPORT_PACKAGE_CAPACITY_EXCEEDED';
  end if;
  if to_regclass('pg_temp.tidas_import_package_entries_v2') is null then
    create temporary table tidas_import_package_entries_v2 (
      ordinal integer primary key,
      worker_job_id uuid not null,
      source_artifact_id uuid not null,
      plan_sha256 text not null,
      entry jsonb not null,
      entry_bytes bigint not null,
      disposition text
    ) on commit drop;
    create unique index on tidas_import_package_entries_v2((entry->>'table'),(entry->>'id'),(entry->>'version'));
  end if;
  -- Never trust a caller-created temporary object inside a definer routine.
  if (select relowner from pg_class where oid=to_regclass('pg_temp.tidas_import_package_entries_v2')) <> current_user::regrole::oid then
    raise exception using errcode='42501', message='TIDAS_IMPORT_PACKAGE_STAGE_OWNER_INVALID';
  end if;
  if exists (select 1 from pg_temp.tidas_import_package_entries_v2
    where worker_job_id <> p_worker_job_id or source_artifact_id <> p_source_artifact_id or plan_sha256 <> p_plan_sha256) then
    raise exception using errcode='55000', message='TIDAS_IMPORT_PLAN_MISMATCH';
  end if;
  insert into pg_temp.tidas_import_package_entries_v2(ordinal,worker_job_id,source_artifact_id,plan_sha256,entry,entry_bytes)
  select p_offset + ordinality::integer - 1,p_worker_job_id,p_source_artifact_id,p_plan_sha256,value,octet_length(value::text)
  from jsonb_array_elements(p_entries) with ordinality;
  if (select sum(entry_bytes) from pg_temp.tidas_import_package_entries_v2) > 2147483648 then
    raise exception using errcode='54000', message='TIDAS_IMPORT_PACKAGE_CAPACITY_EXCEEDED';
  end if;
end $_$;

ALTER FUNCTION "private"."tidas_import_package_stage_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_offset" integer, "p_entries" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."tidas_import_package_stage_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_offset" integer, "p_entries" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."tidas_import_package_stage_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_offset" integer, "p_entries" "jsonb") TO "service_role";
