-- Database #746: modern secret keys are API keys, not JWT bearer tokens.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create or replace function util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  service_key text;
  request_headers jsonb;
begin
  service_key := util.project_secret_key();
  request_headers := pg_catalog.jsonb_build_object(
    'Content-Type', 'application/json',
    'apikey', service_key,
    'x_region', 'us-east-1'
  );

  -- Retain the legacy JWT-key transport. Modern sb_secret_ keys must not
  -- enter the Edge runtime's Authorization/JWT authentication path.
  if not pg_catalog.starts_with(service_key, 'sb_secret_') then
    request_headers := request_headers || pg_catalog.jsonb_build_object(
      'Authorization', 'Bearer ' || service_key
    );
  end if;

  perform net.http_post(
    url => util.project_url() || '/functions/v1/' || name,
    headers => request_headers,
    body => body,
    timeout_milliseconds => timeout_milliseconds
  );
end;
$$;

commit;
