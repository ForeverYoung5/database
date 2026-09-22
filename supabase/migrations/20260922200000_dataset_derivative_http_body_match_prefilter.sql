-- Database #689: the protected whole-preflight (and the real admit transaction) quarantines one
-- derivative target at a time through util.quarantine_dataset_derivative_rebuild_target, and every
-- quarantine call deletes from net.http_request_queue by scanning the queue and JSON-parsing each
-- candidate body through util.dataset_derivative_rebuild_http_body_matches. Inside the rollback-only
-- simulation the queue accumulates one uncommitted dispatch per target (measured: 387 rows /
-- 23.4 MB) and no drainer can remove them, so the total work is quadratic body parses: measured at
-- 6.5 s of 14.1 s preflight for the 387-action synthetic cohort and 11.3 s of 22.3 s for the
-- structure-model cohort that matches the real plan's published structure counts.
--
-- This migration keeps the predicate exact and only removes impossible parses: every matching
-- branch compares a parsed JSON string value against p_id::text, so when the id bytes are absent
-- from the body AND the body contains no backslash byte (no JSON escape sequence can hide the id),
-- no JSON string inside the body can decode to the id and the parse cannot match. Bodies carrying
-- any backslash still take the original full parse path. The function is otherwise byte-identical
-- to its deployed definition; no signature, owner, ACL, caller or returned material changes.
create or replace function util.dataset_derivative_rebuild_http_body_matches(
  p_body bytea,
  p_table text,
  p_id uuid,
  p_version text
) returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_body jsonb;
begin
  if p_body is null
    or p_table is null
    or p_table not in ('flows', 'processes') then
    return false;
  end if;
  -- Conservative byte pre-filter: without the id bytes and without any backslash the decoded body
  -- cannot produce the id through an escape sequence, so the parse below cannot match. The bytea
  -- overload of pg_catalog.position takes the haystack first (unlike the `position(x in y)` text
  -- form), so p_body is the first argument.
  if pg_catalog.position(p_body, pg_catalog.convert_to(p_id::text, 'UTF8')) = 0
    and pg_catalog.position(p_body, '\x5c'::bytea) = 0 then
    return false;
  end if;
  v_body := pg_catalog.convert_from(p_body, 'UTF8')::jsonb;
  if jsonb_typeof(v_body) = 'object' then
    return v_body #>> '{record,id}' = p_id::text
      and btrim(v_body #>> '{record,version}') = p_version
      and coalesce(v_body->>'table', 'processes') = p_table;
  end if;

  if jsonb_typeof(v_body) = 'array' then
    return exists (
      select 1
      from jsonb_array_elements(v_body) as job(value)
      where job.value->>'id' = p_id::text
        and btrim(job.value->>'version') = p_version
        and job.value->>'schema' = 'public'
        and job.value->>'table' = p_table
        and job.value->>'embeddingColumn' = 'embedding_ft'
    );
  end if;

  return false;
exception
  when others then
    return false;
end;
$$;

alter function util.dataset_derivative_rebuild_http_body_matches(
  bytea,
  text,
  uuid,
  text
) owner to postgres;
revoke all on function util.dataset_derivative_rebuild_http_body_matches(
  bytea,
  text,
  uuid,
  text
) from public, anon, authenticated, service_role;
