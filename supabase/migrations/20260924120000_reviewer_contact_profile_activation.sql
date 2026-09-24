begin;

create or replace function private.review_contact_references_ready(
  p_json_ordered jsonb,
  p_self_id uuid
) returns boolean
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_ref record;
  v_table text;
  v_exists boolean;
begin
  if p_json_ordered #>> '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet,@refObjectId}'
       is distinct from p_self_id::text then
    return false;
  end if;

  for v_ref in
    with recursive nodes(value) as (
      select coalesce(
        p_json_ordered #- '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet}',
        '{}'::jsonb
      )
      union all
      select child.value
      from nodes
      cross join lateral (
        select value from jsonb_each(
          case when jsonb_typeof(nodes.value) = 'object' then nodes.value else '{}'::jsonb end
        )
        union all
        select value from jsonb_array_elements(
          case when jsonb_typeof(nodes.value) = 'array' then nodes.value else '[]'::jsonb end
        )
      ) child
    )
    select distinct
      value->>'@type' as ref_type,
      (value->>'@refObjectId')::uuid as ref_id,
      value->>'@version' as ref_version
    from nodes
    where jsonb_typeof(value) = 'object'
      and coalesce(value->>'@refObjectId', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and nullif(value->>'@version', '') is not null
      and value->>'@type' in (
        'contact data set', 'source data set', 'unit group data set',
        'flow property data set', 'flow data set', 'process data set',
        'lifeCycleModel data set'
      )
  loop
    v_table := case v_ref.ref_type
      when 'contact data set' then 'contacts'
      when 'source data set' then 'sources'
      when 'unit group data set' then 'unitgroups'
      when 'flow property data set' then 'flowproperties'
      when 'flow data set' then 'flows'
      when 'process data set' then 'processes'
      when 'lifeCycleModel data set' then 'lifecyclemodels'
    end;

    execute format(
      'select exists(select 1 from public.%I where id = $1 and version = $2 and state_code = 100)',
      v_table
    ) into v_exists using v_ref.ref_id, v_ref.ref_version;

    if not coalesce(v_exists, false) then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

create or replace function api.qry_review_get_my_contact_status()
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_contact jsonb;
  v_row jsonb;
  v_id uuid;
  v_version text;
  v_ready boolean := false;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED', 'status', 401,
      'message', 'Authentication required');
  end if;

  if not exists (
    select 1 from private.roles
    where user_id = v_actor
      and team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and role = 'review-member'
  ) then
    return jsonb_build_object('ok', false, 'code', 'REVIEW_MEMBER_REQUIRED', 'status', 403,
      'message', 'Reviewer membership is required');
  end if;

  select contact into v_contact from private.users where id = v_actor;

  if v_contact is null or v_contact = 'null'::jsonb then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'status', 'missing', 'ready', false, 'contact', null, 'dataset', null));
  end if;

  begin
    v_id := nullif(v_contact->>'@refObjectId', '')::uuid;
    v_version := nullif(v_contact->>'@version', '');
  exception when invalid_text_representation then
    v_id := null;
  end;

  if v_id is not null and v_version is not null then
    select jsonb_build_object(
      'id', id, 'version', version, 'state_code', state_code,
      'rule_verification', rule_verification, 'json_ordered', json_ordered::jsonb
    ) into v_row
    from public.contacts
    where id = v_id and version = v_version and user_id = v_actor;

    v_ready := v_row is not null
      and coalesce((v_row->>'state_code')::integer, 0) = 100
      and coalesce((v_row->>'rule_verification')::boolean, false);
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'status', case when v_ready then 'ready' else 'invalid' end,
    'ready', v_ready,
    'contact', v_contact,
    'dataset', v_row
  ));
end;
$$;

create or replace function api.cmd_review_contact_activate(
  p_mode text,
  p_id uuid,
  p_json_ordered jsonb,
  p_operation_id uuid,
  p_source_version text default null,
  p_bind boolean default true,
  p_expected_contact jsonb default null,
  p_audit jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_current_contact jsonb;
  v_result jsonb;
  v_created jsonb;
  v_version text;
  v_payload jsonb;
  v_owner_ref jsonb;
  v_contact_ref jsonb;
  v_replay jsonb;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED', 'status', 401,
      'message', 'Authentication required');
  end if;

  if not exists (
    select 1 from private.roles
    where user_id = v_actor
      and team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and role = 'review-member'
  ) then
    return jsonb_build_object('ok', false, 'code', 'REVIEW_MEMBER_REQUIRED', 'status', 403,
      'message', 'Reviewer membership is required');
  end if;

  if p_mode not in ('create', 'createVersion') or p_id is null or p_operation_id is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_REVIEWER_CONTACT_REQUEST', 'status', 400,
      'message', 'A valid reviewer contact request is required');
  end if;

  perform pg_advisory_xact_lock(hashtext('cmd_review_contact_activate'), hashtext(v_actor::text));

  select payload->'result' into v_replay
  from private.command_audit_log
  where command = 'cmd_review_contact_activate'
    and actor_user_id = v_actor
    and payload->>'operation_id' = p_operation_id::text
  order by created_at desc
  limit 1;
  if v_replay is not null then
    return v_replay || jsonb_build_object('idempotent_replay', true);
  end if;

  if p_json_ordered is null or not (p_json_ordered ? 'contactDataSet') then
    return jsonb_build_object('ok', false, 'code', 'INVALID_REVIEWER_CONTACT_REQUEST', 'status', 400,
      'message', 'A valid reviewer contact request is required');
  end if;

  v_owner_ref := jsonb_build_object(
    '@refObjectId', p_id::text,
    '@type', 'contact data set',
    '@uri', '../contacts/' || p_id::text || '.xml',
    '@version', coalesce(
      p_json_ordered #>> '{contactDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}',
      p_source_version,
      '01.00.000'
    ),
    'common:shortDescription', coalesce(
      p_json_ordered #> '{contactDataSet,contactInformation,dataSetInformation,common:shortName}',
      '[]'::jsonb
    )
  );
  p_json_ordered := jsonb_set(
    p_json_ordered,
    '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet}',
    v_owner_ref,
    true
  );

  if p_json_ordered #>> '{contactDataSet,contactInformation,dataSetInformation,common:UUID}'
       is distinct from p_id::text
     or p_json_ordered #> '{contactDataSet,contactInformation,dataSetInformation,common:shortName}'
       is null
     or p_json_ordered #> '{contactDataSet,contactInformation,dataSetInformation,common:name}'
       is null
     or p_json_ordered #> '{contactDataSet,contactInformation,dataSetInformation,classificationInformation,common:classification}'
       is null
     or nullif(p_json_ordered #>> '{contactDataSet,administrativeInformation,dataEntryBy,common:timeStamp}', '')
       is null
     or nullif(p_json_ordered #>> '{contactDataSet,administrativeInformation,dataEntryBy,common:referenceToDataSetFormat,@refObjectId}', '')
       is null
     or coalesce(p_json_ordered #>> '{contactDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}', '')
       !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$' then
    return jsonb_build_object('ok', false, 'code', 'REVIEWER_CONTACT_VALIDATION_REQUIRED', 'status', 400,
      'message', 'Reviewer contact must contain the validated required profile fields');
  end if;

  select contact into v_current_contact
  from private.users where id = v_actor for update;

  if v_current_contact is distinct from p_expected_contact then
    return jsonb_build_object('ok', false, 'code', 'REVIEWER_CONTACT_CHANGED', 'status', 409,
      'message', 'The reviewer contact binding changed; reload and try again');
  end if;

  if p_mode = 'create' and v_current_contact is not null then
    return jsonb_build_object('ok', false, 'code', 'REVIEWER_CONTACT_ALREADY_BOUND', 'status', 409,
      'message', 'A reviewer contact is already bound');
  end if;

  if p_mode = 'createVersion' then
    if p_source_version is null
       or v_current_contact->>'@refObjectId' is distinct from p_id::text
       or v_current_contact->>'@version' is distinct from p_source_version
       or not exists (
         select 1 from public.contacts
         where id = p_id and version = p_source_version
           and user_id = v_actor and state_code = 100
       ) then
      return jsonb_build_object('ok', false, 'code', 'REVIEWER_CONTACT_SOURCE_INVALID', 'status', 409,
        'message', 'The bound reviewer contact is not an eligible version source');
    end if;
  end if;

  if not private.review_contact_references_ready(p_json_ordered, p_id) then
    return jsonb_build_object('ok', false, 'code', 'REVIEWER_CONTACT_REFERENCE_NOT_OPEN', 'status', 400,
      'message', 'Reviewer contact references must point to open data');
  end if;

  if p_mode = 'create' then
    v_result := api.cmd_dataset_create('contacts', p_id, p_json_ordered, null, true,
      coalesce(p_audit, '{}'::jsonb) || jsonb_build_object('reviewerProfile', true), null);
  else
    v_result := api.cmd_dataset_create_version('contacts', p_id, p_source_version,
      p_json_ordered, null, true,
      coalesce(p_audit, '{}'::jsonb) || jsonb_build_object('reviewerProfile', true), null);
  end if;

  if not coalesce((v_result->>'ok')::boolean, false) then
    return v_result;
  end if;

  v_created := v_result->'data';
  v_version := v_created->>'version';
  select json_ordered::jsonb into v_payload
  from public.contacts
  where id = p_id and version = v_version and user_id = v_actor;
  v_owner_ref := jsonb_build_object(
    '@refObjectId', p_id::text,
    '@type', 'contact data set',
    '@uri', '../contacts/' || p_id::text || '.xml',
    '@version', v_version,
    'common:shortDescription', coalesce(
      p_json_ordered #> '{contactDataSet,contactInformation,dataSetInformation,common:shortName}',
      '[]'::jsonb
    )
  );
  v_payload := jsonb_set(
    v_payload,
    '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet}',
    v_owner_ref,
    true
  );

  update public.contacts
  set json_ordered = v_payload::json,
      rule_verification = true,
      state_code = 100,
      modified_at = now()
  where id = p_id and version = v_version and user_id = v_actor
  returning jsonb_build_object(
    'id', id, 'version', version, 'state_code', state_code,
    'rule_verification', rule_verification, 'json_ordered', json_ordered::jsonb
  ) into v_created;

  if v_created is null then
    raise exception using errcode = 'P0001', message = 'REVIEWER_CONTACT_ACTIVATION_FAILED';
  end if;

  v_contact_ref := jsonb_build_object(
    '@refObjectId', p_id::text,
    '@type', 'contact data set',
    '@uri', '../contacts/' || p_id::text || '.xml',
    '@version', v_version,
    'common:shortDescription', coalesce(
      v_payload #> '{contactDataSet,contactInformation,dataSetInformation,common:shortName}',
      '[]'::jsonb
    )
  );

  if p_mode = 'create' or p_bind then
    update private.users set contact = v_contact_ref where id = v_actor;
  end if;

  v_result := jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'dataset', v_created,
      'contact', v_contact_ref,
      'bound', p_mode = 'create' or p_bind
    ),
    'idempotent_replay', false
  );

  insert into private.command_audit_log(
    command, actor_user_id, target_table, target_id, target_version, payload
  ) values (
    'cmd_review_contact_activate', v_actor, 'contacts', p_id, v_version,
    coalesce(p_audit, '{}'::jsonb) || jsonb_build_object(
      'operation_id', p_operation_id::text,
      'mode', p_mode,
      'bind', p_mode = 'create' or p_bind,
      'result', v_result
    )
  );

  return v_result;
end;
$$;

alter function private.review_contact_references_ready(jsonb, uuid) owner to postgres;
revoke all on function private.review_contact_references_ready(jsonb, uuid) from public, anon, authenticated, service_role;

alter function api.qry_review_get_my_contact_status() owner to postgres;
revoke all on function api.qry_review_get_my_contact_status() from public, anon, service_role;
grant execute on function api.qry_review_get_my_contact_status() to authenticated;

alter function api.cmd_review_contact_activate(text, uuid, jsonb, uuid, text, boolean, jsonb, jsonb) owner to postgres;
revoke all on function api.cmd_review_contact_activate(text, uuid, jsonb, uuid, text, boolean, jsonb, jsonb) from public, anon, service_role;
grant execute on function api.cmd_review_contact_activate(text, uuid, jsonb, uuid, text, boolean, jsonb, jsonb) to authenticated;

insert into private.api_capability_grants(
  routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role
) values
  ('api.qry_review_get_my_contact_status()', 'NX-REV-01', false, true, false),
  ('api.cmd_review_contact_activate(text, uuid, jsonb, uuid, text, boolean, jsonb, jsonb)', 'NX-REV-01', false, true, false)
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;

notify pgrst, 'reload schema';

commit;
