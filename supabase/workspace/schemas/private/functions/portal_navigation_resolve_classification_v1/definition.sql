CREATE OR REPLACE FUNCTION "private"."portal_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer DEFAULT NULL::integer) RETURNS "text"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_taxonomies text[];
  v_code text;
  v_label text;
  v_depth integer;
  v_node text;
  v_hits integer;
begin
  select coalesce(array_agg(taxonomy), '{}'::text[]) into v_taxonomies
  from unnest(private.portal_navigation_classification_taxonomy_v1(p_system)) taxonomy
  where (p_kind='process' and taxonomy='isic') or (p_kind='flow' and taxonomy in ('cpc','elementary'));
  v_code := private.portal_navigation_classification_code_v1(p_value);
  v_label := private.portal_navigation_classification_label_v1(p_value);
  v_depth := coalesce(
    p_level,
    case
      when pg_catalog.jsonb_typeof(p_value -> '@level') = 'string'
        and (p_value ->> '@level') ~ '^[0-9]{1,2}$'
        then (p_value ->> '@level')::integer
      else null
    end
  );

  if v_code is null then
    return null;
  end if;

  select pg_catalog.count(*)::integer, pg_catalog.min(node.node_id)
  into v_hits, v_node
  from private.portal_navigation_node_v1 as node
  where node.dimension = 'classification'
    and node.taxonomy = any (v_taxonomies)
    and node.taxonomy <> 'database-virtual'
    and node.source_file is not null
    and pg_catalog.lower(node.code) = pg_catalog.lower(v_code);

  -- Two applicable taxonomies can share a spelling (ISIC and CPC share 337
  -- codes), so an ambiguous hit is never guessed.
  if v_hits = 1 then return v_node; end if;
  -- Some authored elementary categories contain a name instead of an id. Only
  -- a unique source label is admissible; array position is never a tree depth.
  if v_hits=0 and v_taxonomies = array['elementary']::text[] then
    select count(*), min(node.node_id) into v_hits,v_node
    from private.portal_navigation_node_v1 node
    where node.taxonomy='elementary' and exists (
      select 1 from jsonb_each_text(node.labels) label
      where lower(label.value)=lower(v_code)
    );
    if v_hits=1 then return v_node; end if;
  end if;
  return null;
end;
$_$;

ALTER FUNCTION "private"."portal_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer) OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer) FROM PUBLIC;
