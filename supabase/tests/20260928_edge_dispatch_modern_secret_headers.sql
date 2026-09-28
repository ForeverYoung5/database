-- Run only on an isolated local stack; every fixture change is rolled back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(14);

select ok((select prosecdef from pg_catalog.pg_proc
  where oid = 'util.invoke_edge_function(text,jsonb,integer)'::regprocedure),
  'dispatch remains SECURITY DEFINER');
select is((select pg_catalog.pg_get_userbyid(proowner)::text from pg_catalog.pg_proc
  where oid = 'util.invoke_edge_function(text,jsonb,integer)'::regprocedure),
  'postgres', 'dispatch retains its postgres owner');
select ok((select proconfig @> array['search_path=""'] from pg_catalog.pg_proc
  where oid = 'util.invoke_edge_function(text,jsonb,integer)'::regprocedure),
  'dispatch retains the fixed empty search_path');
select ok(not pg_catalog.has_function_privilege('anon',
  'util.invoke_edge_function(text,jsonb,integer)', 'EXECUTE'),
  'anonymous users cannot dispatch');
select ok(not pg_catalog.has_function_privilege('authenticated',
  'util.invoke_edge_function(text,jsonb,integer)', 'EXECUTE'),
  'authenticated users cannot dispatch');

create or replace function util.project_url() returns text
language sql security definer set search_path = ''
as $$ select 'https://synthetic.invalid'::text $$;
create or replace function util.project_secret_key() returns text
language sql security definer set search_path = ''
as $$ select pg_catalog.current_setting('dispatch746.fixture_key') $$;

-- pg_net sends requests only after commit. Inspect real queued requests and
-- roll back this transaction, so no synthetic request can leave the database.
create temporary view dispatch746_calls as
select url, pg_catalog.convert_from(body, 'UTF8')::jsonb as body,
  headers, timeout_milliseconds, method
from net.http_request_queue
where url like 'https://synthetic.invalid/functions/v1/%';

set local dispatch746.fixture_key = 'sb_secret_synthetic_not_a_credential';
select util.invoke_edge_function('embedding_ft', '[{"jobId":746}]'::jsonb, 12345);
select is((select count(*)::integer from dispatch746_calls), 1,
  'modern-key dispatch makes exactly one HTTP call');
select is((select headers from dispatch746_calls),
  '{"Content-Type":"application/json","apikey":"sb_secret_synthetic_not_a_credential","x_region":"us-east-1"}'::jsonb,
  'modern secret keys use apikey without an Authorization header');
select is((select url from dispatch746_calls),
  'https://synthetic.invalid/functions/v1/embedding_ft', 'function URL is preserved');
select is((select body from dispatch746_calls), '[{"jobId":746}]'::jsonb,
  'batch body is preserved');
select is((select timeout_milliseconds from dispatch746_calls), 12345,
  'explicit timeout is preserved');
select is((select method from dispatch746_calls), 'POST',
  'dispatch preserves the POST method');

delete from net.http_request_queue
where url like 'https://synthetic.invalid/functions/v1/%';
set local dispatch746.fixture_key = 'eyJsynthetic.eyJsynthetic.signature';
select util.invoke_edge_function('embedding', '{}'::jsonb);
select is((select headers from dispatch746_calls),
  '{"Content-Type":"application/json","apikey":"eyJsynthetic.eyJsynthetic.signature","Authorization":"Bearer eyJsynthetic.eyJsynthetic.signature","x_region":"us-east-1"}'::jsonb,
  'legacy JWT keys retain both the apikey and Bearer transport');
select is((select timeout_milliseconds from dispatch746_calls), 300000,
  'the five-minute default timeout is preserved');
select is((select count(*)::integer from dispatch746_calls), 1,
  'legacy-key dispatch makes exactly one HTTP call');

select * from finish();
rollback;
