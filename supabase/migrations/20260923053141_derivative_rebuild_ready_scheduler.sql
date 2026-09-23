-- Separate runnable work from bounded primary-drift audits. The visit limit and
-- all business phases remain unchanged; at most five visits per invocation may
-- produce new external work. No historical row is backfilled.
alter table util.dataset_derivative_rebuild_requests
  add column scheduler_selected_at timestamp with time zone;

comment on column util.dataset_derivative_rebuild_requests.scheduler_selected_at is
  'Internal progress-slot service clock for actor/batch fairness; NULL until selected. Waiting/overflow audits never update it. Not part of public read or plan hashes.';

create function private.pick_dataset_derivative_rebuild_request(
  p_seen uuid[],
  p_lane text,
  p_allow_external boolean,
  p_now timestamp with time zone
) returns table(request_id uuid, is_ready boolean, dispatch_capable boolean)
language sql volatile security invoker set search_path = ''
as $selector$
  with active as materialized (
    select r.id, r.actor_user_id, coalesce(r.batch_id, r.id) as scheduling_batch,
      r.status, r.phase, r.updated_at, r.admitted_at, r.drain_not_before,
      r.failure_release_not_before, r.markdown_request_id, r.markdown_deadline_at,
      r.embedding_queue_msg_id, r.embedding_pending_job_id, r.embedding_deadline_at
    from util.dataset_derivative_rebuild_requests r
    where r.status not in ('completed', 'stale', 'failed')
      and not (r.id = any(coalesce(p_seen, array[]::uuid[])))
  ), actors as materialized (
    select history.actor_user_id,
      coalesce(max(history.scheduler_selected_at), min(history.admitted_at)) as last_served
    from util.dataset_derivative_rebuild_requests history
    where history.actor_user_id in (select active.actor_user_id from active)
    group by history.actor_user_id
  ), batches as materialized (
    select history.actor_user_id, coalesce(history.batch_id, history.id) as scheduling_batch,
      coalesce(max(history.scheduler_selected_at), min(history.admitted_at)) as last_served
    from util.dataset_derivative_rebuild_requests history
    where (history.actor_user_id, coalesce(history.batch_id, history.id)) in
      (select active.actor_user_id, active.scheduling_batch from active)
    group by history.actor_user_id, coalesce(history.batch_id, history.id)
  ), readiness as materialized (
    select active.*,
      coalesce(case
        when active.status = 'queued' then true
        when active.status = 'dispatching' and active.phase = 'quarantining'
          then active.drain_not_before <= p_now
        when active.status = 'dispatching' and active.phase = 'failure_draining'
          then active.failure_release_not_before <= p_now
        when active.status = 'markdown_pending' then
          exists (select 1 from net._http_response response where response.id = active.markdown_request_id)
          or active.markdown_deadline_at <= p_now
        when active.status = 'embedding_pending' then
          case
            when active.embedding_queue_msg_id is not null then
              not exists (select 1 from pgmq.q_embedding_jobs job where job.msg_id = active.embedding_queue_msg_id)
              or active.embedding_deadline_at <= p_now
            when active.embedding_pending_job_id is null then true
            when pending.status = 'pending' then active.embedding_deadline_at <= p_now
            else true -- bridge, lost or malformed proof: let the unchanged body decide
          end
        else false
      end, false) as ready
    from active
    left join util.pending_embedding_jobs pending on pending.id = active.embedding_pending_job_id
  ), classified as (
    select readiness.*,
      ready and (status = 'markdown_pending'
        or (status = 'dispatching' and phase = 'quarantining')) as external
    from readiness
  )
  select locked.id, classified.ready, classified.external
  from classified
  join util.dataset_derivative_rebuild_requests locked on locked.id = classified.id
  join actors on actors.actor_user_id = classified.actor_user_id
  join batches on batches.actor_user_id = classified.actor_user_id
    and batches.scheduling_batch = classified.scheduling_batch
  where locked.status not in ('completed', 'stale', 'failed')
    and (p_lane in ('audit', 'any') or (p_lane = 'ready' and classified.ready))
    and (p_lane = 'audit' or not classified.external or p_allow_external)
  order by
    case when p_lane in ('audit', 'any') then classified.updated_at else actors.last_served end,
    case when p_lane in ('audit', 'any') then classified.admitted_at else batches.last_served end,
    classified.updated_at, classified.admitted_at, classified.id
  -- Lock/skip first, then count the actual row. Pre-limiting a ranked candidate
  -- list would strand runnable peers behind another session's locked quota.
  for update of locked skip locked
  limit 1
$selector$;

alter function private.pick_dataset_derivative_rebuild_request(uuid[], text, boolean, timestamp with time zone)
  owner to postgres;
revoke all on function private.pick_dataset_derivative_rebuild_request(uuid[], text, boolean, timestamp with time zone)
  from public, anon, authenticated, service_role;
comment on function private.pick_dataset_derivative_rebuild_request(uuid[], text, boolean, timestamp with time zone) is
  'Owner-only narrow-metadata selector. Fair actor/batch progress and oldest-row audits; acquires at most one actual request lock after SKIP LOCKED, with no pre-lock lane quota.';
CREATE OR REPLACE FUNCTION util.process_dataset_derivative_rebuilds(p_limit integer DEFAULT 5)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_request util.dataset_derivative_rebuild_requests%rowtype;
  v_candidate record;
  v_seen uuid[] := array[]::uuid[];
  v_visit_limit integer;
  v_ready_slots integer;
  v_slot integer;
  v_lane text;
  v_ready_exhausted boolean := false;
  v_audit_only boolean;
  v_audited integer := 0;
  v_external_visits integer := 0;
  v_external_transition boolean;
  v_json_ordered jsonb;
  v_response net._http_response%rowtype;
  v_snapshot jsonb;
  v_quarantine jsonb;
  v_service_key text;
  v_http_request_id bigint;
  v_proposal_count integer;
  v_proposal_id bigint;
  v_queue_mode text;
  v_queue_msg_id bigint;
  v_pending_job_id bigint;
  v_pending_status text;
  v_pending_msg_id bigint;
  v_pending_enqueued_at timestamp with time zone;
  v_embedding_failure jsonb;
  v_processed integer := 0;
  v_now timestamp with time zone;
  v_error_state text;
  v_error_message text;
  v_error_detail text;
begin
  if coalesce(p_limit, 0) <= 0 then
    return 0;
  end if;

  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtext('util.process_dataset_derivative_rebuilds')
  ) then
    return 0;
  end if;

  v_visit_limit := least(greatest(p_limit, 1), 25);
  v_ready_slots := case when v_visit_limit = 1 then 1
    else v_visit_limit - least(5, greatest(1, v_visit_limit / 5)) end;
  for v_slot in 1..v_visit_limit loop
    v_lane := case when v_visit_limit = 1 then 'any'
      when v_slot <= v_ready_slots and not v_ready_exhausted then 'ready'
      else 'audit' end;
    if v_lane = 'audit' and v_audited >= 5 then
      exit;
    end if;
    select candidate.* into v_candidate
    from private.pick_dataset_derivative_rebuild_request(
      v_seen, v_lane, v_external_visits < 5, pg_catalog.clock_timestamp()
    ) candidate;
    if v_candidate.request_id is null and v_lane = 'ready' then
      v_ready_exhausted := true;
      v_lane := 'audit';
      if v_audited >= 5 then exit; end if;
      select candidate.* into v_candidate
      from private.pick_dataset_derivative_rebuild_request(
        v_seen, v_lane, false, pg_catalog.clock_timestamp()
      ) candidate;
    end if;
    if v_candidate.request_id is null then
      exit;
    end if;
    v_seen := array_append(v_seen, v_candidate.request_id);
    select request.* into v_request
    from util.dataset_derivative_rebuild_requests request
    where request.id = v_candidate.request_id;
    v_processed := v_processed + 1;
    v_now := pg_catalog.clock_timestamp();
    -- Recheck the actual locked phase as well as the earlier readiness snapshot.
    -- A state change between metadata selection and locking cannot bypass the
    -- external budget. Over-reserving for an invalid response remains conservative.
    v_external_transition := v_candidate.dispatch_capable
      or v_request.status = 'markdown_pending'
      or (v_request.status = 'dispatching' and v_request.phase = 'quarantining'
        and v_request.drain_not_before <= v_now);
    -- Ready work in the oldest-row lane receives a real progress slot if capacity
    -- remains. It is then stamped/counted as progress, never as a waiting audit.
    v_audit_only := not v_candidate.is_ready
      or (v_external_transition and v_external_visits >= 5);
    if v_audit_only then
      v_audited := v_audited + 1;
    else
      if v_external_transition then
        v_external_visits := v_external_visits + 1;
      end if;
      -- Outside the request-scoped exception block: a poisoned selected request
      -- still consumed a service opportunity, while audits never count as progress.
      update util.dataset_derivative_rebuild_requests
      set scheduler_selected_at = v_now where id = v_request.id;
    end if;
    begin

    if v_audit_only and v_request.status = 'dispatching'
      and v_request.phase = 'failure_draining' then
      update util.dataset_derivative_rebuild_requests
      set updated_at = v_now where id = v_request.id;
      continue;
    end if;

    if v_request.status = 'dispatching'
      and v_request.phase = 'failure_draining' then
      if v_request.failure_release_not_before is null
        or v_now < v_request.failure_release_not_before then
        update util.dataset_derivative_rebuild_requests
        set updated_at = v_now
        where id = v_request.id;
        continue;
      end if;

      v_quarantine := util.quarantine_dataset_derivative_rebuild_target(
        v_request.target_table,
        v_request.target_id,
        v_request.target_version
      );
      update util.dataset_derivative_rebuild_proposals
      set
        status = 'discarded',
        discarded_at = v_now
      where request_id = v_request.id
        and status in ('captured', 'accepted');

      update util.dataset_derivative_rebuild_requests
      set
        status = 'failed',
        phase = 'failed_drained',
        terminal_at = v_now,
        drained_at = v_now,
        quarantined_http_requests = quarantined_http_requests
          + coalesce((v_quarantine->>'http_requests')::integer, 0),
        quarantined_embedding_jobs = quarantined_embedding_jobs
          + coalesce((v_quarantine->>'embedding_jobs')::integer, 0),
        quarantined_pending_jobs = quarantined_pending_jobs
          + coalesce((v_quarantine->>'pending_jobs')::integer, 0),
        updated_at = v_now
      where id = v_request.id;
      perform util.record_dataset_derivative_rebuild_terminal(v_request.id);
      continue;
    end if;

    v_json_ordered := null;
    if v_request.target_table = 'flows' then
      select flow.json_ordered::jsonb
      into v_json_ordered
      from public.flows as flow
      where flow.id = v_request.target_id
        and btrim(flow.version::text) = v_request.target_version;
    elsif v_request.target_table = 'processes' then
      select process.json_ordered::jsonb
      into v_json_ordered
      from public.processes as process
      where process.id = v_request.target_id
        and btrim(process.version::text) = v_request.target_version;
    end if;

    if v_json_ordered is null
      or not util.dataset_derivative_rebuild_primary_matches(v_request) then
      perform util.fail_dataset_derivative_rebuild_after_drain(
        v_request.id,
        'DERIVATIVE_PRIMARY_DRIFT',
        'Frozen dataset primary fingerprint is no longer present',
        '{}'::jsonb
      );
      continue;
    end if;

    if v_audit_only then
      update util.dataset_derivative_rebuild_requests
      set updated_at = v_now where id = v_request.id;
      continue;
    end if;

    if v_request.status = 'queued' then
      update util.dataset_derivative_rebuild_requests
      set
        status = 'dispatching',
        phase = 'quarantining',
        updated_at = v_now
      where id = v_request.id;
      continue;
    end if;

    if v_request.status = 'dispatching'
      and v_request.phase = 'quarantining' then
      if v_now < v_request.drain_not_before then
        update util.dataset_derivative_rebuild_requests
        set updated_at = v_now
        where id = v_request.id;
        continue;
      end if;

      v_quarantine := util.quarantine_dataset_derivative_rebuild_target(
        v_request.target_table,
        v_request.target_id,
        v_request.target_version
      );
      update util.dataset_derivative_rebuild_proposals
      set
        status = 'discarded',
        discarded_at = v_now
      where request_id = v_request.id
        and status in ('captured', 'accepted');

      v_service_key := util.project_secret_key();
      v_http_request_id := net.http_post(
        url => util.project_url()
          || case v_request.target_table
            when 'flows' then '/functions/v1/webhook_flow_embedding_ft'
            else '/functions/v1/webhook_process_embedding_ft'
          end,
        headers => jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_service_key,
          'apikey', v_service_key,
          'x_region', 'us-east-1'
        ),
        body => jsonb_build_object(
          'type', 'UPDATE',
          'schema', 'public',
          'table', v_request.target_table,
          'record', jsonb_build_object(
            'id', v_request.target_id,
            'version', v_request.target_version,
            'json_ordered', v_json_ordered
          ),
          'old_record', jsonb_build_object(
            'id', v_request.target_id,
            'version', v_request.target_version,
            'json_ordered', v_json_ordered
          ),
          'derivativeRebuildRequestId', v_request.id
        ),
        timeout_milliseconds => 120000
      );

      update util.dataset_derivative_rebuild_requests
      set
        status = 'markdown_pending',
        phase = 'markdown_dispatched',
        markdown_request_id = v_http_request_id,
        markdown_dispatched_at = v_now,
        markdown_deadline_at = v_now + interval '10 minutes',
        quarantined_http_requests = quarantined_http_requests
          + coalesce((v_quarantine->>'http_requests')::integer, 0),
        quarantined_embedding_jobs = quarantined_embedding_jobs
          + coalesce((v_quarantine->>'embedding_jobs')::integer, 0),
        quarantined_pending_jobs = quarantined_pending_jobs
          + coalesce((v_quarantine->>'pending_jobs')::integer, 0),
        updated_at = v_now
      where id = v_request.id;
      continue;
    end if;

    if v_request.status = 'markdown_pending' then
      v_response := null;
      select response.*
      into v_response
      from net._http_response as response
      where response.id = v_request.markdown_request_id;

      if v_response.id is null then
        if v_request.markdown_deadline_at is not null
          and v_now >= v_request.markdown_deadline_at then
          delete from net.http_request_queue
          where id = v_request.markdown_request_id;
          perform util.fail_dataset_derivative_rebuild_after_drain(
            v_request.id,
            'DERIVATIVE_MARKDOWN_RESPONSE_TIMEOUT',
            'Markdown webhook did not produce a durable response before deadline',
            jsonb_build_object(
              'markdown_request_id',
              v_request.markdown_request_id::text
            )
          );
        end if;
        update util.dataset_derivative_rebuild_requests
        set updated_at = v_now
        where id = v_request.id;
        continue;
      end if;

      update util.dataset_derivative_rebuild_requests
      set
        markdown_response_status = v_response.status_code,
        markdown_response_received_at = v_response.created,
        updated_at = v_now
      where id = v_request.id;

      if coalesce(v_response.timed_out, false)
        or v_response.error_msg is not null
        or v_response.status_code not between 200 and 299
        or not util.dataset_derivative_rebuild_markdown_response_matches(
          v_response.content,
          v_request.target_table,
          v_request.target_id,
          v_request.target_version
        ) then
        perform util.fail_dataset_derivative_rebuild_after_drain(
          v_request.id,
          'DERIVATIVE_MARKDOWN_RESPONSE_INVALID',
          'Markdown webhook response was timed out, non-2xx, or malformed',
          jsonb_build_object(
            'markdown_request_id', v_request.markdown_request_id::text,
            'status_code', v_response.status_code,
            'timed_out', v_response.timed_out,
            'error_msg', v_response.error_msg
          )
        );
        continue;
      end if;

      select count(*), min(proposal.id)
      into v_proposal_count, v_proposal_id
      from util.dataset_derivative_rebuild_proposals as proposal
      where proposal.request_id = v_request.id
        and proposal.proposal_kind = 'markdown'
        and proposal.status = 'captured'
        and proposal.captured_at >= v_request.markdown_dispatched_at;

      if v_proposal_count <> 1 then
        perform util.fail_dataset_derivative_rebuild_after_drain(
          v_request.id,
          'DERIVATIVE_MARKDOWN_PROPOSAL_MISMATCH',
          'Markdown response did not correlate to exactly one staged proposal',
          jsonb_build_object('proposal_count', v_proposal_count)
        );
        continue;
      end if;

      update util.dataset_derivative_rebuild_proposals
      set status = 'accepted'
      where id = v_proposal_id
        and request_id = v_request.id
        and proposal_kind = 'markdown'
        and status = 'captured';

      update util.dataset_derivative_rebuild_requests
      set
        markdown_proposal_id = v_proposal_id,
        accepted_extracted_md_sha256 = (
          select proposal.extracted_md_sha256
          from util.dataset_derivative_rebuild_proposals as proposal
          where proposal.id = v_proposal_id
        ),
        updated_at = v_now
      where id = v_request.id;

      select policy.mode
      into v_queue_mode
      from util.embedding_queue_policy_for(
        'public',
        v_request.target_table,
        'embedding_ft',
        'embedding_ft'
      ) as policy;

      if v_queue_mode = 'normal' then
        select pgmq.send(
          queue_name => 'embedding_jobs',
          msg => jsonb_build_object(
            'id', v_request.target_id,
            'version', v_request.target_version,
            'schema', 'public',
            'table', v_request.target_table,
            'contentFunction',
              case v_request.target_table
                when 'flows'
                  then 'flows_derivative_rebuild_embedding_input'
                else 'processes_derivative_rebuild_embedding_input'
              end,
            'embeddingColumn', 'embedding_ft',
            'edgeFunction', 'embedding_ft',
            'requestId', v_request.id,
            'expectedPrimarySnapshotSha256',
              v_request.expected_snapshot_sha256,
            'expectedMarkdownSha256', (
              select proposal.extracted_md_sha256
              from util.dataset_derivative_rebuild_proposals as proposal
              where proposal.id = v_proposal_id
            )
          )
        ) into v_queue_msg_id;

        update util.dataset_derivative_rebuild_requests
        set
          status = 'embedding_pending',
          phase = 'embedding_queued',
          embedding_queue_msg_id = v_queue_msg_id,
          embedding_queued_at = v_now,
          embedding_deadline_at = v_now + interval '7 days',
          updated_at = v_now
        where id = v_request.id;
      else
        insert into util.pending_embedding_jobs (
          schema_name,
          table_name,
          record_id,
          record_version,
          content_function,
          embedding_column,
          edge_function,
          message
        ) values (
          'public',
          v_request.target_table,
          v_request.target_id::text,
          v_request.target_version,
          case v_request.target_table
                when 'flows'
                  then 'flows_derivative_rebuild_embedding_input'
                else 'processes_derivative_rebuild_embedding_input'
              end,
          'embedding_ft',
          'embedding_ft',
          jsonb_build_object(
            'id', v_request.target_id,
            'version', v_request.target_version,
            'schema', 'public',
            'table', v_request.target_table,
            'contentFunction',
              case v_request.target_table
                when 'flows'
                  then 'flows_derivative_rebuild_embedding_input'
                else 'processes_derivative_rebuild_embedding_input'
              end,
            'embeddingColumn', 'embedding_ft',
            'edgeFunction', 'embedding_ft',
            'requestId', v_request.id,
            'expectedPrimarySnapshotSha256',
              v_request.expected_snapshot_sha256,
            'expectedMarkdownSha256', (
              select proposal.extracted_md_sha256
              from util.dataset_derivative_rebuild_proposals as proposal
              where proposal.id = v_proposal_id
            )
          )
        )
        on conflict (
          schema_name,
          table_name,
          record_id,
          record_version,
          embedding_column,
          edge_function
        ) where status = 'pending'
        do update set
          message = excluded.message,
          updated_at = v_now
        returning id into v_pending_job_id;

        update util.dataset_derivative_rebuild_requests
        set
          status = 'embedding_pending',
          phase = case
            when v_queue_mode = 'paused'
              then 'embedding_policy_paused'
            else 'embedding_policy_deferred'
          end,
          embedding_pending_job_id = v_pending_job_id,
          embedding_queued_at = v_now,
          embedding_deadline_at = v_now + interval '7 days',
          updated_at = v_now
        where id = v_request.id;
      end if;
      continue;
    end if;

    if v_request.status = 'embedding_pending' then
      v_queue_msg_id := v_request.embedding_queue_msg_id;
      v_pending_status := null;
      v_pending_msg_id := null;
      v_pending_enqueued_at := null;
      v_embedding_failure := null;

      if v_queue_msg_id is null
        and v_request.embedding_pending_job_id is not null then
        select pending.status, pending.queue_msg_id, pending.enqueued_at
        into v_pending_status, v_pending_msg_id, v_pending_enqueued_at
        from util.pending_embedding_jobs as pending
        where pending.id = v_request.embedding_pending_job_id;

        if v_pending_status = 'pending' then
          if v_request.embedding_deadline_at is not null
            and v_now >= v_request.embedding_deadline_at then
            delete from util.pending_embedding_jobs
            where id = v_request.embedding_pending_job_id;
            perform util.fail_dataset_derivative_rebuild_after_drain(
              v_request.id,
              'DERIVATIVE_EMBEDDING_POLICY_TIMEOUT',
              'Embedding policy did not release the request before deadline',
              '{}'::jsonb
            );
          end if;
          update util.dataset_derivative_rebuild_requests
          set updated_at = v_now
          where id = v_request.id;
          continue;
        end if;

        if v_pending_status = 'enqueued'
          and v_pending_msg_id is not null
          and v_pending_enqueued_at is not null then
          v_queue_msg_id := v_pending_msg_id;
          update util.dataset_derivative_rebuild_requests
          set
            phase = 'embedding_queued',
            embedding_queue_msg_id = v_queue_msg_id,
            embedding_queued_at = v_pending_enqueued_at,
            updated_at = v_now
          where id = v_request.id;
        else
          perform util.fail_dataset_derivative_rebuild_after_drain(
            v_request.id,
            'DERIVATIVE_EMBEDDING_PENDING_JOB_LOST',
            'Request-specific pending embedding job is missing or discarded',
            '{}'::jsonb
          );
          continue;
        end if;
      end if;

      if v_queue_msg_id is null then
        perform util.fail_dataset_derivative_rebuild_after_drain(
          v_request.id,
          'DERIVATIVE_EMBEDDING_QUEUE_PROOF_MISSING',
          'Request-specific embedding queue id is missing',
          '{}'::jsonb
        );
        continue;
      end if;

      if exists (
        select 1
        from pgmq.q_embedding_jobs as job
        where job.msg_id = v_queue_msg_id
      ) then
        if v_request.embedding_deadline_at is not null
          and v_now >= v_request.embedding_deadline_at then
          delete from pgmq.q_embedding_jobs
          where msg_id = v_queue_msg_id;
          perform util.fail_dataset_derivative_rebuild_after_drain(
            v_request.id,
            'DERIVATIVE_EMBEDDING_QUEUE_TIMEOUT',
            'Embedding job did not finish before deadline',
            jsonb_build_object('queue_msg_id', v_queue_msg_id::text)
          );
        end if;
        update util.dataset_derivative_rebuild_requests
        set updated_at = v_now
        where id = v_request.id;
        continue;
      end if;

      select jsonb_build_object(
        'failure_id', failure.id::text,
        'reason', failure.reason,
        'failed_at', failure.failed_at
      )
      into v_embedding_failure
      from util.embedding_job_failures as failure
      where failure.msg_id = v_queue_msg_id
      order by failure.id desc
      limit 1;

      if v_embedding_failure is not null then
        perform util.fail_dataset_derivative_rebuild_after_drain(
          v_request.id,
          'DERIVATIVE_EMBEDDING_JOB_FAILED',
          'Request-specific embedding job reached the failure ledger',
          v_embedding_failure
        );
        continue;
      end if;

      select count(*), min(proposal.id)
      into v_proposal_count, v_proposal_id
      from util.dataset_derivative_rebuild_proposals as proposal
      where proposal.request_id = v_request.id
        and proposal.proposal_kind = 'embedding'
        and proposal.status = 'captured'
        and proposal.captured_at >= v_request.embedding_queued_at;

      if v_proposal_count <> 1 then
        perform util.fail_dataset_derivative_rebuild_after_drain(
          v_request.id,
          'DERIVATIVE_EMBEDDING_PROPOSAL_MISMATCH',
          'Embedding ACK did not correlate to exactly one staged proposal',
          jsonb_build_object(
            'queue_msg_id', v_queue_msg_id::text,
            'proposal_count', v_proposal_count
          )
        );
        continue;
      end if;

      perform util.commit_dataset_derivative_rebuild_proposal(
        v_request.id,
        v_request.markdown_proposal_id,
        v_proposal_id
      );

      v_snapshot := util.dataset_derivative_rebuild_snapshot(
        v_request.target_table,
        v_request.target_id,
        v_request.target_version
      );

      if v_snapshot->>'embedding_ft_sha256' is null
        or v_snapshot->>'extracted_md_sha256' is null
        or (v_snapshot->>'embedding_ft_at')::timestamp with time zone
          <= coalesce(
            v_request.before_embedding_ft_at,
            '-infinity'::timestamp with time zone
          ) then
        raise exception using
          errcode = '40001',
          message = 'Committed derivative snapshot is not fresh and complete';
      end if;

      update util.dataset_derivative_rebuild_requests
      set
        status = 'completed',
        phase = 'completed',
        embedding_proposal_id = v_proposal_id,
        completed_snapshot_sha256 = v_snapshot->>'snapshot_sha256',
        completed_at = v_now,
        terminal_at = v_now,
        drained_at = v_now,
        updated_at = v_now
      where id = v_request.id;
      perform util.record_dataset_derivative_rebuild_terminal(v_request.id);
    end if;
    exception
      when others then
        get stacked diagnostics
          v_error_state = returned_sqlstate,
          v_error_message = message_text,
          v_error_detail = pg_exception_detail;
        perform util.fail_dataset_derivative_rebuild_after_drain(
          v_request.id,
          'DERIVATIVE_COORDINATOR_ERROR',
          'Unexpected request-scoped coordinator error',
          jsonb_build_object(
            'sqlstate', v_error_state,
            'message', v_error_message,
            'detail', v_error_detail
          )
        );
    end;
  end loop;

  return v_processed;
end;
$function$;
