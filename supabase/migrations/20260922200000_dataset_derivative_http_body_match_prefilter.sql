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
-- branch compares a parsed JSON string value against p_id::text, and a UUID text consists only of
-- [0-9a-f-], so the only escape sequence that can produce a character of it is the Unicode escape
-- `\uXXXX`; the single-character escapes (`\"` `\\` `\/` `\b` `\f` `\n` `\r` `\t`) produce only
-- characters outside that set. Therefore, when the id bytes are absent from the body AND the body
-- contains no `\u` prefix, no parsed JSON string inside it can equal the id and the parse cannot
-- match. Falling back on the `\u` prefix rather than on any backslash is what keeps the fast path
-- live for real dispatch bodies, which are built from to_jsonb(NEW)/to_jsonb(OLD) and therefore
-- carry ordinary escape sequences (`\n`, `\"`, `\\`) from Markdown content on essentially every
-- row. A body containing any `\u` (including the escaped-backslash decoy `\\u`) still takes the
-- original full parse path, so the predicate stays conservative. The function is otherwise
-- byte-identical to its deployed definition; no signature, owner, ACL, caller or returned material
-- changes.
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
  -- Conservative byte pre-filter: without the id bytes and without any `\u` escape prefix the
  -- decoded body cannot produce the id (only Unicode escapes can spell characters of a UUID text),
  -- so the parse below cannot return true. The bytea overload of pg_catalog.position takes the
  -- haystack first (unlike the `position(x in y)` text form), so p_body is the first argument;
  -- '\x5c75' is the two-byte `\u` sequence.
  --
  -- One deliberate difference, visible only to a caller that inspects the raw value: for an
  -- object-shaped body whose record.id is absent or JSON null (with neither the version nor the
  -- table comparison false) the pre-#689 body returned SQL NULL while this early return yields
  -- false. The true-set is identical - the early return fires only where the original could not
  -- return true - and every caller consumes this function in a positive filter context
  -- (DELETE/COUNT ... WHERE, WHERE EXISTS, LEFT JOIN ... ON) where NULL and false select the same
  -- rows; the batch suite pins the class and the call-site evidence is recorded with the #689
  -- review.
  if pg_catalog.position(p_body, pg_catalog.convert_to(p_id::text, 'UTF8')) = 0
    and pg_catalog.position(p_body, '\x5c75'::bytea) = 0 then
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
