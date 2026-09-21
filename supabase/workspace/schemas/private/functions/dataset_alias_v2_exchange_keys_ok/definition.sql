CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_exchange_keys_ok"("p_exchange" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select jsonb_typeof(p_exchange) = 'object'
    and not exists (
      select 1
      from jsonb_object_keys(p_exchange) as key(name)
      where key.name <> all (array[
        '@dataSetInternalID', 'meanAmount', 'resultingAmount', 'referenceToFlowDataSet',
        'exchangeDirection', 'dataDerivationTypeStatus', 'uncertaintyDistributionType',
        'relativeStandardDeviation95In', 'generalComment', 'common:other', 'name', 'unit'
      ])
    )
$$;

ALTER FUNCTION "private"."dataset_alias_v2_exchange_keys_ok"("p_exchange" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_exchange_keys_ok"("p_exchange" "jsonb") FROM PUBLIC;
