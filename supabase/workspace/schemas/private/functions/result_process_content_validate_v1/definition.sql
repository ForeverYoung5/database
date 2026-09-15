CREATE OR REPLACE FUNCTION "private"."result_process_content_validate_v1"("p_text" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_document json;
  v_root_uuid text;
  v_root_version text;
begin
  begin
    v_document := p_text::json;
  exception when others then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message', 'contentText is not valid JSON');
  end;

  if not (v_document IS JSON OBJECT WITH UNIQUE KEYS) then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message',
      'contentText must be a JSON object with no duplicate keys at any level');
  end if;

  if json_typeof(v_document -> 'processDataSet') is distinct from 'object' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message', 'contentText must contain processDataSet');
  end if;

  v_root_uuid := v_document #>>
    '{processDataSet,processInformation,dataSetInformation,common:UUID}';
  v_root_version := v_document #>>
    '{processDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}';

  if json_typeof(v_document #> '{processDataSet,processInformation,dataSetInformation}') is distinct from 'object'
     or json_typeof(v_document #> '{processDataSet,processInformation,dataSetInformation,common:UUID}') is distinct from 'string'
     or lower(v_root_uuid) <> p_id::text then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message', 'processDataSet common:UUID must be a string equal to id');
  end if;

  if json_typeof(v_document #> '{processDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}') is distinct from 'string'
     or v_root_version <> p_version then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message',
      'publicationAndOwnership common:dataSetVersion must be a string equal to version');
  end if;

  return jsonb_build_object('ok', true, 'document', v_document);
end;
$$;

ALTER FUNCTION "private"."result_process_content_validate_v1"("p_text" "text", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_content_validate_v1"("p_text" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."result_process_content_validate_v1"("p_text" "text", "p_id" "uuid", "p_version" "text") TO "api_internal_executor";
