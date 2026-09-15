CREATE OR REPLACE FUNCTION "private"."maintain_lcia_scope_closure_candidate_cache"("p_max_rows" integer DEFAULT 2000, "p_lock_timeout_ms" integer DEFAULT 5000) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_deleted integer := 0;
  v_remaining bigint;
  v_rows integer;
  v_previous_lock_timeout text := pg_catalog.current_setting('lock_timeout');
  v_result jsonb;
begin
  if p_max_rows is null or p_max_rows < 1 or p_max_rows > 10000 then
    raise exception using
      errcode = '22023',
      message = 'invalid_candidate_cache_maintenance_batch';
  end if;

  if p_lock_timeout_ms is null
     or p_lock_timeout_ms < 1
     or p_lock_timeout_ms > 60000 then
    raise exception using
      errcode = '22023',
      message = 'invalid_candidate_cache_maintenance_lock_timeout';
  end if;

  perform pg_catalog.set_config(
    'lock_timeout',
    p_lock_timeout_ms::text || 'ms',
    true
  );

  begin
    -- The fence. Any source write in flight either committed before this lock is
    -- granted, in which case its cache effect is already present and accounted for,
    -- or it starts after the batch completes.
    lock table public.processes in share row exclusive mode;
  exception
    when lock_not_available then
      perform pg_catalog.set_config('lock_timeout', v_previous_lock_timeout, true);
      return jsonb_build_object(
        'status', 'lock_timeout',
        'removedCount', 0,
        'remainingCount', null,
        'batchLimit', p_max_rows,
        'moreRemaining', true,
        'lockTimeoutMs', p_lock_timeout_ms
      );
  end;

  -- Candidate decision and delete are one statement, taken under the fence so the
  -- decision cannot be invalidated before the delete. The nested LIMIT subquery
  -- selects exactly p_max_rows identities in the same deterministic order used by
  -- the residual probe below, and the delete re-evaluates each cache row's primary
  -- key against that selection rather than deleting by a separately built key list.
  delete from private.lcia_scope_closure_candidate_document_hashes as cache
  where cache.dataset_type = 'processes'
    and (cache.dataset_id, cache.dataset_version) in (
      select target.dataset_id, target.dataset_version
      from (
        select cache_row.dataset_id, cache_row.dataset_version
        from private.lcia_scope_closure_candidate_document_hashes as cache_row
        left join public.processes as process_row
          on process_row.id = cache_row.source_locator_id
         and btrim(process_row.version::text) = cache_row.dataset_version
        where cache_row.dataset_type = 'processes'
          and (
            process_row.id is null
            or process_row.state_code is distinct from 100
            or process_row.json_ordered is null
          )
        order by cache_row.dataset_id, cache_row.dataset_version
        limit p_max_rows
      ) as target
    );
  get diagnostics v_rows = row_count;
  v_deleted := v_rows;

  -- Residual after this batch: one row past the limit is enough to decide whether
  -- more work remains; the exact total is never claimed.
  select count(*)
  into v_remaining
  from (
    select 1
    from private.lcia_scope_closure_candidate_document_hashes as cache
    left join public.processes as process_row
      on process_row.id = cache.source_locator_id
     and btrim(process_row.version::text) = cache.dataset_version
    where cache.dataset_type = 'processes'
      and (
        process_row.id is null
        or process_row.state_code is distinct from 100
        or process_row.json_ordered is null
      )
    limit p_max_rows + 1
  ) as probe;

  v_result := jsonb_build_object(
    'status', 'ok',
    'removedCount', v_deleted,
    'remainingCount',
      case when v_remaining > p_max_rows then null else v_remaining end,
    'batchLimit', p_max_rows,
    'moreRemaining', (v_remaining > 0),
    'lockTimeoutMs', p_lock_timeout_ms
  );

  perform pg_catalog.set_config('lock_timeout', v_previous_lock_timeout, true);
  return v_result;
exception
  when others then
    perform pg_catalog.set_config('lock_timeout', v_previous_lock_timeout, true);
    raise;
end;
$$;

ALTER FUNCTION "private"."maintain_lcia_scope_closure_candidate_cache"("p_max_rows" integer, "p_lock_timeout_ms" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."maintain_lcia_scope_closure_candidate_cache"("p_max_rows" integer, "p_lock_timeout_ms" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."maintain_lcia_scope_closure_candidate_cache"("p_max_rows" integer, "p_lock_timeout_ms" integer) TO "api_internal_executor";
