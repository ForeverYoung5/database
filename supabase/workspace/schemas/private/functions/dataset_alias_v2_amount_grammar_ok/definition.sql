CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_amount_grammar_ok"("p_amount" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select
    p_amount is not null
    and octet_length(p_amount) between 1 and 64
    and p_amount ~ '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]{1,2})?$'
    and (
      p_amount !~ '[eE]'
      or abs(replace(substring(p_amount from '[eE]([+-]?[0-9]{1,2})$'), '+', '')::integer) <= 30
    )
$_$;

ALTER FUNCTION "private"."dataset_alias_v2_amount_grammar_ok"("p_amount" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_amount_grammar_ok"("p_amount" "text") FROM PUBLIC;
