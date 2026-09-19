-- Initial navigation projection backfill, UUID quarter 3/4.
-- Claim only missing versions; never overwrite a concurrent source writer.
begin;
set local lock_timeout='5s';
set local statement_timeout='15min';
do $backfill$
declare v record; inserted integer;
begin
  for v in
    select src.dataset_kind,src.id,src.version,src.card from private.portal_catalog_search_current_v2 src
    where src.id >= '80000000-0000-0000-0000-000000000000'::uuid and src.id < 'c0000000-0000-0000-0000-000000000000'::uuid
      and not exists(select 1 from private.portal_navigation_versions_v1 n
        where (n.dataset_kind,n.id,n.version)=(src.dataset_kind,src.id,src.version))
    order by src.id,src.dataset_kind,src.version
  loop
    begin

    insert into private.portal_navigation_versions_v1(dataset_kind,id,version,access_level,
      geography_code,classification_codes,reference_year,process_subtype,source)
    values(v.dataset_kind,v.id,v.version,v.card->>'accessLevel',lower(btrim(v.card#>>'{geography,code}')),
      array(select distinct lower(btrim(x->>'code')) from jsonb_array_elements(coalesce(v.card->'classifications','[]')) x
        where nullif(btrim(x->>'code'),'') is not null),
      (v.card->>'referenceYear')::integer,lower(btrim(v.card->>'processSubtype')),lower(btrim(v.card->>'source')))
    on conflict do nothing;
    get diagnostics inserted = row_count;
    if inserted>0 then perform private.sync_portal_navigation_membership_v1(v.dataset_kind,v.id,v.version,v.card); end if;

    exception when foreign_key_violation then
      -- A withdrawal is allowed to win. Any other broken reference still fails.
      if exists(select 1 from private.portal_catalog_search_current_v2 p
        where (p.dataset_kind,p.id,p.version)=(v.dataset_kind,v.id,v.version)) then raise; end if;
    end;
  end loop;
end;
$backfill$;
commit;
