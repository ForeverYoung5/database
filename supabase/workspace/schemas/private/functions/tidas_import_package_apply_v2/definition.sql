CREATE OR REPLACE FUNCTION "private"."tidas_import_package_apply_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_entry_count" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_user uuid;
  v_plan private.tidas_import_plans_v2%rowtype;
  v_previous private.tidas_import_packages_v2%rowtype;
  v_source_sha text;
  v_entries_sha text;
  v_entry jsonb;
  v_row record;
  v_table text;
  v_id uuid;
  v_version text;
  v_inserted bigint;
  v_count bigint := 0;
  v_items jsonb;
  v_receipt jsonb;
begin
  v_user := private.tidas_import_guard_v2(p_worker_job_id,p_lease_token,p_source_artifact_id);
  if p_plan_sha256 is null or p_plan_sha256 !~ '^[0-9a-f]{64}$'
    or p_entry_count is null or p_entry_count < 1 or p_entry_count > 100000
    or to_regclass('pg_temp.tidas_import_package_entries_v2') is null then
    raise exception using errcode='22023', message='TIDAS_IMPORT_PACKAGE_INVALID';
  end if;
  if (select relowner from pg_class where oid=to_regclass('pg_temp.tidas_import_package_entries_v2')) <> current_user::regrole::oid then
    raise exception using errcode='42501', message='TIDAS_IMPORT_PACKAGE_STAGE_OWNER_INVALID';
  end if;
  if (select count(*) from pg_temp.tidas_import_package_entries_v2) <> p_entry_count
    or (select min(ordinal) from pg_temp.tidas_import_package_entries_v2) <> 0
    or (select max(ordinal) from pg_temp.tidas_import_package_entries_v2) <> p_entry_count - 1
    or exists (select 1 from pg_temp.tidas_import_package_entries_v2 where worker_job_id <> p_worker_job_id
      or source_artifact_id <> p_source_artifact_id or plan_sha256 <> p_plan_sha256) then
    raise exception using errcode='22023', message='TIDAS_IMPORT_PACKAGE_STAGE_MISMATCH';
  end if;
  select artifact_sha256 into v_source_sha from private.lca_package_artifacts where id=p_source_artifact_id;
  insert into private.tidas_import_plans_v2(worker_job_id,source_artifact_id,source_sha256,plan_sha256)
  values(p_worker_job_id,p_source_artifact_id,v_source_sha,p_plan_sha256) on conflict(worker_job_id) do nothing;
  select * into v_plan from private.tidas_import_plans_v2 where worker_job_id=p_worker_job_id for update;
  if v_plan.source_artifact_id <> p_source_artifact_id or v_plan.source_sha256 <> v_source_sha
    or v_plan.plan_sha256 <> p_plan_sha256
    or exists(select 1 from private.tidas_import_groups_v2 where worker_job_id=p_worker_job_id) then
    raise exception using errcode='55000', message='TIDAS_IMPORT_PLAN_MISMATCH';
  end if;
  select encode(extensions.digest(convert_to(string_agg(
    encode(extensions.digest(convert_to(entry::text,'UTF8'),'sha256'),'hex'), '' order by ordinal),'UTF8'),'sha256'),'hex')
  into v_entries_sha from pg_temp.tidas_import_package_entries_v2;
  select * into v_previous from private.tidas_import_packages_v2 where worker_job_id=p_worker_job_id;
  if found then
    if v_previous.entries_sha256 <> v_entries_sha then
      raise exception using errcode='55000', message='TIDAS_IMPORT_PACKAGE_REPLAY_MISMATCH';
    end if;
    return v_previous.receipt;
  end if;
  for v_row in select ordinal,entry from pg_temp.tidas_import_package_entries_v2 order by
    case entry ->> 'table' when 'contacts' then 1 when 'sources' then 2 when 'unitgroups' then 3
      when 'flowproperties' then 4 when 'flows' then 5 when 'lifecyclemodels' then 6 when 'processes' then 7 else 8 end,
    entry ->> 'id', entry ->> 'version'
  loop
    v_entry := v_row.entry;
    v_table := v_entry ->> 'table';
    v_id := (v_entry ->> 'id')::uuid;
    v_version := v_entry ->> 'version';
    if v_table is null or v_table not in ('contacts','sources','unitgroups','flowproperties','flows','lifecyclemodels','processes')
       or v_id is null or v_version is null or v_version !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
       or jsonb_typeof(v_entry -> 'json_ordered') is distinct from 'object' then
      raise exception using errcode = '22023', message = 'TIDAS_IMPORT_ENTRY_INVALID';
    end if;
    if v_table = 'lifecyclemodels' then
      insert into public.lifecyclemodels(id, version, json_ordered, rule_verification, json_tg, user_id)
      values (v_id, v_version, v_entry -> 'json_ordered', coalesce((v_entry ->> 'rule_verification')::boolean, true),
        coalesce(nullif(v_entry -> 'json_tg', 'null'::jsonb), '{}'::jsonb), v_user)
      on conflict (id, version) do nothing;
    elsif v_table = 'processes' then
      insert into public.processes(id, version, json_ordered, rule_verification, model_id, user_id)
      values (v_id, v_version, v_entry -> 'json_ordered', coalesce((v_entry ->> 'rule_verification')::boolean, true),
        (v_entry ->> 'model_id')::uuid, v_user)
      on conflict (id, version) do nothing;
    else
      execute format('insert into public.%I(id, version, json_ordered, rule_verification, user_id)
        values ($1,$2,$3,$4,$5) on conflict (id, version) do nothing', v_table)
      using v_id, v_version, v_entry -> 'json_ordered', coalesce((v_entry ->> 'rule_verification')::boolean, true), v_user;
    end if;
    get diagnostics v_inserted = row_count;
    v_count := v_count + v_inserted;

    update pg_temp.tidas_import_package_entries_v2 set disposition=case when v_inserted=1 then 'inserted' else 'existing' end
    where ordinal=v_row.ordinal;
  end loop;
  select jsonb_agg(jsonb_build_object('table',entry->>'table','id',entry->>'id','version',entry->>'version',
    'disposition',disposition) order by ordinal) into v_items from pg_temp.tidas_import_package_entries_v2;
  v_receipt := jsonb_build_object('import_mode','whole_package','status',case when v_count>0 then 'imported' else 'reused' end,
    'inserted_count',v_count,'existing_count',p_entry_count-v_count,'items',v_items,
    'root_count',(select count(*) from pg_temp.tidas_import_package_entries_v2 where entry->>'table' in ('processes','lifecyclemodels')));
  insert into private.tidas_import_packages_v2(worker_job_id,entries_sha256,receipt) values(p_worker_job_id,v_entries_sha,v_receipt);
  -- Keep heartbeats possible during inserts, then fence immediately before commit.
  perform 1 from private.worker_jobs where id=p_worker_job_id for update;
  perform private.tidas_import_guard_v2(p_worker_job_id,p_lease_token,p_source_artifact_id);
  return v_receipt;
end $_$;

ALTER FUNCTION "private"."tidas_import_package_apply_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_entry_count" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."tidas_import_package_apply_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_entry_count" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."tidas_import_package_apply_v2"("p_worker_job_id" "uuid", "p_lease_token" "uuid", "p_source_artifact_id" "uuid", "p_plan_sha256" "text", "p_entry_count" integer) TO "service_role";
