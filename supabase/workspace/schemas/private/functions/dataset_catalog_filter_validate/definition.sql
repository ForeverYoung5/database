CREATE OR REPLACE FUNCTION "private"."dataset_catalog_filter_validate"("p_filter" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'pg_catalog', 'pg_temp'
    AS $_$
declare selected jsonb; part jsonb;
begin
  if p_filter is null then return; end if;
  if jsonb_typeof(p_filter) <> 'object' then
    raise exception using errcode='22023', message='dataset filter must be an object';
  end if;
  if p_filter ? 'flowType' and jsonb_typeof(p_filter->'flowType') is distinct from 'string' then
    raise exception using errcode='22023',message='flowType must be a string';
  end if;
  if p_filter ? 'asInput' and not (
    jsonb_typeof(p_filter->'asInput')='boolean'
    or (jsonb_typeof(p_filter->'asInput')='string' and lower(btrim(p_filter->>'asInput')) in ('true','false'))
  ) then
    raise exception using errcode='22023',message='asInput must be boolean or true/false string';
  end if;
  if p_filter ? 'classification' then
    if jsonb_typeof(p_filter->'classification') <> 'array'
       or jsonb_array_length(p_filter->'classification') > 50 then
      raise exception using errcode='22023', message='classification must be an array of at most 50 selectors';
    end if;
    for selected in select value from jsonb_array_elements(p_filter->'classification') loop
      if jsonb_typeof(selected) <> 'object'
         or coalesce(selected->>'scope','') not in ('classification','elementary')
         or jsonb_typeof(selected->'code') <> 'string'
         or coalesce(btrim(selected->>'code'),'') = ''
         or length(selected->>'code') > 200 then
        raise exception using errcode='22023', message='invalid classification selector';
      end if;
      if selected ? 'system' and (jsonb_typeof(selected->'system') <> 'string'
         or coalesce(btrim(selected->>'system'),'') = '' or length(selected->>'system') > 200) then
        raise exception using errcode='22023', message='invalid classification system';
      end if;
      if selected ? 'path' then
        if jsonb_typeof(selected->'path') <> 'array'
           or jsonb_array_length(selected->'path') not between 1 and 20 then
          raise exception using errcode='22023', message='classification path must contain 1 to 20 codes';
        end if;
        for part in select value from jsonb_array_elements(selected->'path') loop
          if jsonb_typeof(part) <> 'string' or btrim(part #>> '{}') = '' or length(part #>> '{}') > 200 then
            raise exception using errcode='22023', message='invalid classification path code';
          end if;
        end loop;
        if btrim(selected->>'code') <> btrim(selected->'path'->>-1) then
          raise exception using errcode='22023', message='classification code must be the final path code';
        end if;
      end if;
    end loop;
  end if;
  if p_filter ? 'sourceEntityKinds' then
    if jsonb_typeof(p_filter->'sourceEntityKinds') <> 'array' or jsonb_array_length(p_filter->'sourceEntityKinds') not between 1 and 7
      or exists(select 1 from jsonb_array_elements(p_filter->'sourceEntityKinds') item
        where jsonb_typeof(item) <> 'string' or (item #>> '{}') not in ('process','flow','lifecyclemodel','contact','source','unitgroup','flowproperty')) then
      raise exception using errcode='22023',message='invalid source entity kinds';
    end if;
  end if;
  if p_filter ? 'datasetId' and (jsonb_typeof(p_filter->'datasetId') <> 'string'
     or coalesce(p_filter->>'datasetId','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception using errcode='22023', message='datasetId must be a UUID';
  end if;
  if p_filter ? 'flowReference' then
    if jsonb_typeof(p_filter->'flowReference') <> 'object'
       or coalesce(p_filter->'flowReference'->>'id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or (p_filter->'flowReference' ? 'version' and
           (jsonb_typeof(p_filter->'flowReference'->'version') <> 'string'
            or coalesce(p_filter->'flowReference'->>'version','') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'))
       or (p_filter->'flowReference' ? 'direction' and
           lower(coalesce(p_filter->'flowReference'->>'direction','')) not in ('input','output')) then
      raise exception using errcode='22023', message='invalid flow reference filter';
    end if;
  end if;
end;
$_$;

ALTER FUNCTION "private"."dataset_catalog_filter_validate"("p_filter" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_catalog_filter_validate"("p_filter" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."dataset_catalog_filter_validate"("p_filter" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "private"."dataset_catalog_filter_validate"("p_filter" "jsonb") TO "next_public_search_executor";
