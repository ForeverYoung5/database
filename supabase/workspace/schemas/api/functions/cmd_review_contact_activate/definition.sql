CREATE OR REPLACE FUNCTION "api"."cmd_review_contact_activate"("p_mode" "text", "p_id" "uuid", "p_json_ordered" "jsonb", "p_operation_id" "uuid", "p_source_version" "text" DEFAULT NULL::"text", "p_bind" boolean DEFAULT true, "p_expected_contact" "jsonb" DEFAULT NULL::"jsonb", "p_audit" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    AS $_$
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
$_$;

ALTER FUNCTION "api"."cmd_review_contact_activate"("p_mode" "text", "p_id" "uuid", "p_json_ordered" "jsonb", "p_operation_id" "uuid", "p_source_version" "text", "p_bind" boolean, "p_expected_contact" "jsonb", "p_audit" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_review_contact_activate"("p_mode" "text", "p_id" "uuid", "p_json_ordered" "jsonb", "p_operation_id" "uuid", "p_source_version" "text", "p_bind" boolean, "p_expected_contact" "jsonb", "p_audit" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_review_contact_activate"("p_mode" "text", "p_id" "uuid", "p_json_ordered" "jsonb", "p_operation_id" "uuid", "p_source_version" "text", "p_bind" boolean, "p_expected_contact" "jsonb", "p_audit" "jsonb") TO "authenticated";
