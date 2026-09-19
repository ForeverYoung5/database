-- Database #656: bounded Portal catalog-summary execution.
--
-- The anonymous `api.portal_catalog_summary_v1` facade failed with the sanitized
-- `portal catalog unavailable` error on a production-volume catalog. The cause
-- was execution cost, not correctness: every candidate block re-read the
-- `private.portal_catalog_search_current_v2` view, which UNION ALLs both
-- projection tables with no usable index for the kind it was asked about, and
-- the `latest` materialization was re-scanned by each block. The 2-second
-- statement budget was then hit inside the function, and its `query_canceled`
-- handler converted the cancellation into the sanitized error.
--
-- The fix keeps the response byte-identical and removes the repeated scans:
--   * each candidate block reads only the exact base table its kind lives in,
--     instead of the `private.portal_catalog_search_current_v2` view;
--   * the "latest visible version of this id" test becomes an existence probe
--     against the materialized `latest` set instead of a semi-join. The probe is
--     a hash probe into that CTE, not an index lookup: a CTE has no indexes. The
--     cost it removes is the repeated sequential re-scan of both projection
--     tables that the semi-join forced, which the earlier plan showed as a
--     parallel seq scan feeding an unindexed join;
--   * the object type, the facet projection and the response budget are
--     unchanged, and the statement budget stays at 2 seconds.
--
-- Measured on an isolated local stack with a synthetic production-volume
-- catalog (38,380 process projection rows, 57,120 flow projection rows):
-- 2.19 s before (statement timeout, sanitized error), 0.69 s after, with
-- `md5()` of the returned JSON identical before and after.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- The facade is owned by the Portal executor, so the replacement runs as that
-- role and keeps the existing ownership and grants.
grant portal_public_executor to postgres;
grant create on schema api to portal_public_executor;
set local role portal_public_executor;

create or replace function api.portal_catalog_summary_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE PARALLEL RESTRICTED SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '2s'
 SET work_mem TO '32MB'
 SET plan_cache_mode TO 'force_custom_plan'
 SET max_parallel_workers_per_gather TO '0'
 SET jit TO 'off'
 SET row_security TO 'on'
AS $function$

declare
  v_counts jsonb;
  v_latest_modified_at text;
  v_uuid_example jsonb;
  v_cas_example jsonb;
  v_classification_example jsonb;
  v_result jsonb;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();
  perform private.assert_portal_catalog_facet_contract_v1();

  with latest as materialized (
    select distinct on (facet.dataset_kind, facet.id)
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.modified_at,
      facet.state_code
    from private.portal_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1
    order by facet.dataset_kind,
      facet.id,
      facet.version desc,
      facet.modified_at desc,
      facet.state_code desc
  ), counts as (
    select pg_catalog.jsonb_build_object(
        'process', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'process'
        ),
        'flow', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'flow'
        ),
        'total', pg_catalog.count(*)
      ) as value,
      private.portal_timestamp_v1(
        pg_catalog.max(latest.modified_at)
      ) as latest_modified_at
    from latest
  ), uuid_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v2 as candidate
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v1 as candidate
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
  ), uuid_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'uuid',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.id::text,
      'label', candidate.label
    ) as value
    from uuid_candidates as candidate
    order by candidate.preference
    limit 1
  ), cas_unique_values as materialized (
    select candidate.card ->> 'casNumber' as cas_number,
      pg_catalog.min(candidate.id::text)::uuid as id
    from private.portal_catalog_search_rows_v1 as candidate
    where candidate.dataset_kind = 'flow'
      and pg_catalog.jsonb_typeof(candidate.card -> 'casNumber') = 'string'
      and candidate.card ->> 'casNumber' ~
        '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(
        candidate.card ->> 'casNumber'
      ) between 7 and 12
      and private.portal_catalog_summary_valid_cas_v1(
        candidate.card ->> 'casNumber'
      )
    group by candidate.card ->> 'casNumber'
    having pg_catalog.count(*) = 1
    order by candidate.card ->> 'casNumber'
    limit 64
  ), cas_candidates as materialized (
    select candidate.dataset_kind,
      candidate.id,
      candidate.version,
      candidate.modified_at,
      candidate.state_code,
      unique_cas.cas_number,
      private.portal_catalog_summary_label_v1(candidate.card) as label
    from cas_unique_values as unique_cas
    join private.portal_catalog_search_rows_v1 as candidate
      on candidate.dataset_kind = 'flow'
     and candidate.id = unique_cas.id
     and candidate.card ->> 'casNumber' = unique_cas.cas_number
    where exists (
        select 1
        from latest
        where latest.dataset_kind = candidate.dataset_kind
          and latest.id = candidate.id
          and latest.version = candidate.version
      )
      and pg_catalog.jsonb_array_length(
      private.portal_catalog_summary_label_v1(candidate.card)
    ) > 0
    order by unique_cas.cas_number,
      candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), cas_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'cas',
      'datasetKind', 'flow',
      'query', candidate.cas_number,
      'label', candidate.label
    ) as value
    from cas_candidates as candidate
    order by candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), classification_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v2 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v1 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
  ), classification_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'classification',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.code,
      'label', candidate.label
    ) as value
    from classification_candidates as candidate
    order by candidate.preference
    limit 1
  )
  select counts.value,
    counts.latest_modified_at,
    uuid_example.value,
    cas_example.value,
    classification_example.value
  into v_counts,
    v_latest_modified_at,
    v_uuid_example,
    v_cas_example,
    v_classification_example
  from counts
  left join uuid_example on true
  left join cas_example on true
  left join classification_example on true;

  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-catalog-summary.v1',
    'counts', v_counts,
    'latestModifiedAt', v_latest_modified_at,
    'examples', coalesce(pg_catalog.jsonb_agg(
      example.value order by example.ordinality
    ) filter (where example.value is not null), '[]'::jsonb)
  )
  into v_result
  from (values
    (1, v_uuid_example),
    (2, v_cas_example),
    (3, v_classification_example)
  ) as example(ordinality, value);

  if pg_catalog.octet_length(v_result::text) > 16384 then
    raise exception using
      errcode = '54000',
      message = 'Portal catalog summary exceeded its response budget';
  end if;

  return v_result;
exception
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$function$;

reset role;
revoke create on schema api from portal_public_executor;
revoke portal_public_executor from postgres;

commit;
