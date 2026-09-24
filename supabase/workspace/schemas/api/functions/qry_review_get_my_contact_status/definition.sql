CREATE OR REPLACE FUNCTION "api"."qry_review_get_my_contact_status"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "api"."qry_review_get_my_contact_status"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_review_get_my_contact_status"() FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_review_get_my_contact_status"() TO "authenticated";
