CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_fu_apply_rule"("p_before_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case
    when p_before_text is null then null
    -- The shared reviewed rule, literally: quantity `1` or `1.0`, one ASCII space, the single unit token
    -- `a`, then a suffix that starts with an ASCII space and carries at least one character that is
    -- neither space nor tab, with no CR or LF anywhere — and the whole string must match, so a trailing
    -- newline is a different text rather than a tolerated suffix. Every other byte survives unchanged.
    -- Equivalent to the producer's `^(1|1\.0) a( [^\r\n]*[^ \t\r\n][^\r\n]*)$`.
    when p_before_text ~ '^(1|1\.0) a( [^\r\n]*[^ \t\r\n][^\r\n]*)$'
      then regexp_replace(p_before_text, '^(1|1\.0) a', '\1 hr', '')
    else null
  end
$_$;

ALTER FUNCTION "private"."dataset_alias_v2_fu_apply_rule"("p_before_text" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_fu_apply_rule"("p_before_text" "text") FROM PUBLIC;
