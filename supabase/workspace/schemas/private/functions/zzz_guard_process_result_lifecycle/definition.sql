CREATE OR REPLACE FUNCTION "private"."zzz_guard_process_result_lifecycle"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_derivatives constant text[] :=
    array['extracted_md', 'search_text', 'embedding_ft', 'embedding_ft_at'];
begin
  if tg_op = 'DELETE' then
    if old.state_code = 120 then
      raise exception using
        errcode = '55000',
        message = 'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
        detail = 'A published Result Process row cannot be deleted.';
    end if;
    return old;
  end if;

  if old.state_code = 120 then
    if new.json_ordered::text is distinct from old.json_ordered::text then
      raise exception using
        errcode = '55000',
        message = 'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
        detail = 'A published Result Process document cannot be modified.';
    end if;

    if (to_jsonb(new) - v_derivatives) is distinct from (to_jsonb(old) - v_derivatives)
    then
      raise exception using
        errcode = '55000',
        message = 'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
        detail = 'Only extracted_md, search_text, embedding_ft and embedding_ft_at may change on a published Result Process.';
    end if;
  end if;

  return new;
end;
$$;

ALTER FUNCTION "private"."zzz_guard_process_result_lifecycle"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."zzz_guard_process_result_lifecycle"() FROM PUBLIC;
