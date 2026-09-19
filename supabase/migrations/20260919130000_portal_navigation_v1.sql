-- Database #656: Portal navigation projection, navigation RPC and Search/Facets V3.
--
-- Additive only: V2 search/facets, the Hybrid RPCs, every existing projection and
-- every immutable manifest keep their exact behaviour and bytes.
--
-- Count basis is `public_versions`: distinct exact `(dataset_kind, id, version)`
-- identities that match the request predicate. A node's `count` is its subtree
-- (self included) and `directCount` is the subset that authored exactly that
-- node. Duplicate authored paths inside one version, and repeated versions of one
-- id, can never double count.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $portal_navigation_role_guard$
begin
  if not exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'api_internal_executor'
      and not rolcanlogin
      and not rolbypassrls
      and not rolsuper
      and not rolreplication
  ) or not exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'portal_public_executor'
      and not rolcanlogin
      and not rolbypassrls
      and not rolsuper
      and not rolreplication
  ) then
    raise exception 'Portal navigation executor prerequisite is unsafe'
      using errcode = '42501';
  end if;
end;
$portal_navigation_role_guard$;

-- Narrow, public-safe exact-version facts. The existing V1 parent retains both
-- kinds (Process V2 supplies the current Process card); the FK withdraws both
-- this row and its memberships whenever the authoritative public parent leaves.
create table private.portal_navigation_versions_v1 (
  dataset_kind text not null check (dataset_kind in ('process','flow')),
  id uuid not null,
  version text not null,
  process_id uuid generated always as (case when dataset_kind='process' then id end) stored,
  process_version text generated always as (case when dataset_kind='process' then version end) stored,
  access_level text not null,
  geography_code text,
  classification_codes text[] not null,
  reference_year integer,
  process_subtype text,
  source text,
  primary key (dataset_kind,id,version),
  foreign key (dataset_kind,id,version)
    references private.portal_catalog_search_rows_v1(dataset_kind,id,version)
    on update cascade on delete cascade deferrable initially deferred,
  foreign key (dataset_kind,process_id,process_version)
    references private.portal_catalog_search_rows_v2(dataset_kind,id,version)
    on update no action on delete cascade deferrable initially deferred
);
alter table private.portal_navigation_versions_v1 enable row level security;
alter table private.portal_navigation_versions_v1 force row level security;
create policy portal_navigation_versions_read_v1 on private.portal_navigation_versions_v1
  for select to portal_public_executor using (true);
create policy portal_navigation_versions_writer_v1 on private.portal_navigation_versions_v1
  for all to api_internal_executor using (true) with check (true);
revoke all on private.portal_navigation_versions_v1 from public,anon,authenticated,service_role;
grant select(dataset_kind,id,version,access_level,geography_code,classification_codes,reference_year,process_subtype,source) on private.portal_navigation_versions_v1 to portal_public_executor;
grant select,insert,update,delete on private.portal_navigation_versions_v1 to api_internal_executor;
create index portal_navigation_versions_process_parent_v1_idx
  on private.portal_navigation_versions_v1(dataset_kind,process_id,process_version) where process_id is not null;
create index portal_navigation_versions_geography_v1_idx
  on private.portal_navigation_versions_v1 (geography_code,dataset_kind,id,version);

create table private.portal_navigation_membership_v1 (
  dataset_kind text not null
    check (dataset_kind in ('process', 'flow')),
  id uuid not null,
  version text not null
    check (version ~ '^\d{2}\.\d{2}\.\d{3}$'),
  dimension text not null
    check (dimension in ('classification', 'geography')),
  node_id text not null
    references private.portal_navigation_node_v1(node_id)
    on update restrict on delete restrict,
  -- True only when the authored placement is exactly this node. An ancestor row
  -- materialised for the same version is false, so a branch never counts a
  -- version it does not directly contain.
  direct boolean not null,
  primary key (dataset_kind,id,version,dimension,node_id),
  foreign key (dataset_kind,id,version)
    references private.portal_navigation_versions_v1(dataset_kind,id,version)
    on update cascade on delete cascade
);

alter table private.portal_navigation_membership_v1 owner to postgres;
alter table private.portal_navigation_membership_v1 enable row level security;
alter table private.portal_navigation_membership_v1 force row level security;

-- One grouped read per branch page. The primary key starts with version
-- identity; this separate branch index starts with (dimension, node_id) and
-- includes direct so the planner can choose an index-only count when visibility
-- permits. Freshly inserted fixtures may legitimately use a bitmap heap scan.
create index portal_navigation_membership_branch_v1_idx
  on private.portal_navigation_membership_v1
  (dimension, node_id, dataset_kind, id, version) include (direct);

create policy portal_navigation_membership_portal_select_v1
on private.portal_navigation_membership_v1
for select
to portal_public_executor
using (true);

create policy portal_navigation_membership_internal_all_v1
on private.portal_navigation_membership_v1
for all
to api_internal_executor
using (true)
with check (true);

revoke all on table private.portal_navigation_membership_v1
  from public, anon, authenticated, service_role;
grant select(dataset_kind,id,version,dimension,node_id,direct) on table private.portal_navigation_membership_v1
  to portal_public_executor;
grant select, insert, update, delete on table private.portal_navigation_membership_v1
  to api_internal_executor;

grant api_internal_executor to postgres;
grant create on schema private to api_internal_executor;
set role api_internal_executor;

-- ---------------------------------------------------------------------------
-- Card facts: the projection reads only the already public-safe card, never the
-- raw dataset JSON.
-- ---------------------------------------------------------------------------

-- The public card already stores the authored code and label. The `@classId` /
-- `#text` spellings cover the raw ILCD shape the card is derived from.
create function private.portal_navigation_classification_code_v1(p_value jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select nullif(
    pg_catalog.btrim(coalesce(
      p_value ->> '@classId',
      p_value ->> 'code',
      p_value ->> '#text'
    )),
    ''
  )
$function$;

create function private.portal_navigation_classification_label_v1(p_value jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select nullif(
    pg_catalog.btrim(coalesce(
      p_value ->> '#text',
      p_value #>> '{label,0,value}'
    )),
    ''
  )
$function$;

create function private.portal_navigation_geography_code_v1(p_kind text, p_card jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select nullif(pg_catalog.btrim(coalesce(
    p_card #>> '{geography,code}',
    case when p_kind = 'flow' then p_card #>> '{geography,locationOfSupply}' end
  )), '')
$function$;

create function private.portal_navigation_classification_taxonomy_v1(p_system jsonb)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select case pg_catalog.lower(pg_catalog.btrim(coalesce(
    p_system ->> '#text',
    p_system ->> '@name',
    case when pg_catalog.jsonb_typeof(p_system) = 'string' then p_system #>> '{}' end,
    ''
  )))
    when 'isic' then array['isic']::text[]
    when 'cpc' then array['cpc']::text[]
    when 'elementary-flow' then array['elementary']::text[]
    when 'ilcd-flow-categorization' then array['elementary']::text[]
    when 'ilcd' then array['isic','cpc']::text[]
    else '{}'::text[]
  end;
$function$;

-- Resolve one authored classification entry to exactly one vocabulary node.
-- Returning null means "no unambiguous node": the caller keeps the raw code.
create function private.portal_navigation_resolve_classification_v1(
  p_kind text,
  p_system jsonb,
  p_value jsonb,
  p_level integer default null
)
returns text
language plpgsql
stable
parallel safe
set search_path = ''
as $function$
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
$function$;

-- Codes that address a node under a different spelling. The datasets author the
-- Chinese administrative layer as `SD-CN` while the pinned vocabulary spells the
-- same province `CN-SD`; an alias row is what makes both spellings reach one node.
create function private.portal_navigation_resolve_alias_v1(p_dimension text,p_code text)
returns text language sql stable parallel safe set search_path=''
as $function$
  select case when count(*)=1 then min(n.node_id) else null end
  from private.portal_navigation_node_v1 n
  where n.dimension=p_dimension and cardinality(n.alias_codes)>0
    and n.alias_codes @> array[upper(btrim(p_code))]
$function$;

create function private.portal_navigation_raw_node_id_v1(p_scope text, p_code text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select p_scope || ':~' || pg_catalog.substr(
    pg_catalog.encode(
      extensions.digest(
        pg_catalog.convert_to(p_scope || '|' || pg_catalog.upper(pg_catalog.btrim(p_code)), 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    1,
    16
  )
$function$;

-- Map an authored classification system to the taxonomy used for a raw
-- (unresolved) node, which must never collide with a resolved taxonomy name.
create function private.portal_navigation_raw_taxonomy_v1(p_system jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select case pg_catalog.lower(pg_catalog.btrim(coalesce(
    p_system ->> '#text',
    p_system ->> '@name',
    case when pg_catalog.jsonb_typeof(p_system) = 'string' then p_system #>> '{}' end,
    ''
  )))
    when 'isic' then 'isic'
    when 'cpc' then 'cpc'
    when 'elementary-flow' then 'elementary'
    when 'ilcd-flow-categorization' then 'elementary'
    else 'unclassified'
  end;
$function$;

comment on function private.portal_navigation_classification_code_v1(jsonb) is
  'Authored classification code only. Never a derived or inferred value.';

create function private.portal_navigation_virtual_labels_v1(p_key text)
returns jsonb
language sql
immutable
parallel safe
set search_path = ''
as $function$
  select case p_key
    when 'unclassified' then pg_catalog.jsonb_build_object(
      'en', 'Unclassified', 'zh-CN', '未分类', 'de', 'Nicht klassifiziert', 'fr', 'Non classé'
    )
    else pg_catalog.jsonb_build_object(
      'en', 'Unmapped locations', 'zh-CN', '未映射地区',
      'de', 'Nicht zugeordnete Standorte', 'fr', 'Localisations non mappées'
    )
  end;
$function$;

-- Every public version lands in at least one node, so node counts always sum
-- back to the same public-version set the search pages show.
create function private.portal_navigation_ensure_virtual_v1(
  p_node_id text,
  p_dimension text,
  p_taxonomy text,
  p_labels_key text
)
returns void
language sql
volatile
parallel restricted
security definer
set search_path = ''
set row_security = 'on'
as $function$
  insert into private.portal_navigation_node_v1 (
    node_id, parent_node_id, code, taxonomy, dimension,
    source_index_path, source_file, labels, label_strategy
  ) values (
    p_node_id, null, '~', p_taxonomy, p_dimension, null, null,
    private.portal_navigation_virtual_labels_v1(p_labels_key),
    pg_catalog.jsonb_build_object(
      'en', 'database-virtual-container', 'zh-CN', 'database-virtual-container',
      'de', 'database-virtual-container', 'fr', 'database-virtual-container'
    )
  )
  on conflict (node_id) do nothing
$function$;

-- Rebuild the membership rows for one exact public version. The public card is
-- the only input, so a retraction or a state change rewrites membership in the
-- same transaction as the projection row itself.
create function private.sync_portal_navigation_membership_v1(
  p_kind text,
  p_id uuid,
  p_version text,
  p_card jsonb
)
returns void
language plpgsql
volatile
parallel restricted
security definer
set search_path = ''
set row_security = 'on'
as $function$
declare
  v_entry jsonb;
  v_entry_level integer;
  v_placement text;
  v_placements text[] := '{}'::text[];
  v_node text;
  v_code text;
  v_taxonomy text;
  v_raw_root text;
  v_geography text;
  v_matched integer := 0;
  v_raw_parent text;
begin
  insert into private.portal_navigation_versions_v1 (
    dataset_kind,id,version,access_level,geography_code,classification_codes,
    reference_year,process_subtype,source
  ) values (
    p_kind,p_id,p_version,p_card->>'accessLevel',
    lower(btrim(p_card#>>'{geography,code}')),
    array(select distinct lower(btrim(entry->>'code'))
      from jsonb_array_elements(coalesce(p_card->'classifications','[]'::jsonb)) entry
      where nullif(btrim(entry->>'code'),'') is not null),
    (p_card->>'referenceYear')::integer,
    lower(btrim(p_card->>'processSubtype')),lower(btrim(p_card->>'source'))
  ) on conflict (dataset_kind,id,version) do update set
    access_level=excluded.access_level,geography_code=excluded.geography_code,
    classification_codes=excluded.classification_codes,reference_year=excluded.reference_year,
    process_subtype=excluded.process_subtype,source=excluded.source
  where (portal_navigation_versions_v1.access_level,portal_navigation_versions_v1.geography_code,
    portal_navigation_versions_v1.classification_codes,portal_navigation_versions_v1.reference_year,
    portal_navigation_versions_v1.process_subtype,portal_navigation_versions_v1.source)
    is distinct from (excluded.access_level,excluded.geography_code,excluded.classification_codes,
      excluded.reference_year,excluded.process_subtype,excluded.source);
  delete from private.portal_navigation_membership_v1
    where dataset_kind=p_kind and id=p_id and version=p_version;
  for v_entry, v_entry_level in
    select distinct entry.value, (entry.ordinality - 1)::integer as level
    from pg_catalog.jsonb_array_elements(
      case pg_catalog.jsonb_typeof(p_card -> 'classifications')
        when 'array' then p_card -> 'classifications'
        else '[]'::jsonb
      end
    ) with ordinality as entry(value, ordinality)
    where pg_catalog.jsonb_typeof(entry.value) = 'object'
  loop
    v_node := private.portal_navigation_resolve_classification_v1(
      p_kind, v_entry -> 'system', v_entry, v_entry_level
    );
    if v_node is null then
      -- Keep the unknown/ambiguous authored code browsable under its own
      -- taxonomy instead of dropping it or guessing a node.
      v_code := private.portal_navigation_classification_code_v1(v_entry);
      if v_code is null then
        continue;
      end if;
      v_taxonomy := private.portal_navigation_raw_taxonomy_v1(v_entry -> 'system');
      if (p_kind='flow' and v_taxonomy='isic') or (p_kind='process' and v_taxonomy in ('cpc','elementary')) then
        v_taxonomy := 'unclassified';
      end if;
      v_raw_root := 'class:' || v_taxonomy || ':~raw';
      perform private.portal_navigation_ensure_virtual_v1(
        v_raw_root, 'classification', v_taxonomy, 'unmapped'
      );
      v_node := private.portal_navigation_raw_node_id_v1('class:' || v_taxonomy, p_kind || '|' || coalesce(v_entry->>'system','') || '|' || v_code);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_root, v_code, v_taxonomy, 'classification', null, null,
        pg_catalog.jsonb_build_object(
          'en', v_code, 'zh-CN', v_code, 'de', v_code, 'fr', v_code
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
    v_matched := v_matched + 1;
    v_placements := pg_catalog.array_append(v_placements, v_node);
  end loop;

  if v_matched = 0 then
    perform private.portal_navigation_ensure_virtual_v1(
      'class:unclassified', 'classification', 'unclassified', 'unclassified'
    );
    v_placements := pg_catalog.array_append(v_placements, 'class:unclassified');
  end if;

  v_geography := private.portal_navigation_geography_code_v1(p_kind, p_card);
  if v_geography is not null then
    v_node := 'geo:' || pg_catalog.lower(v_geography);
    if not exists(select 1 from private.portal_navigation_node_v1 n where n.node_id=v_node and n.dimension='geography') then
      v_node := coalesce(private.portal_navigation_resolve_alias_v1('geography',v_geography),v_node);
    end if;
    if not exists (
      select 1
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_node and node.dimension = 'geography'
    ) then
      perform private.portal_navigation_ensure_virtual_v1(
        'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
      );
      v_raw_parent := 'geo:unmapped';
      -- This verified code family is only a containing province, never proof of
      -- a particular city boundary or geographic precision.
      if upper(v_geography) ~ '^CN-[A-Z]{2}-[A-Z0-9-]+$' then
        select node.node_id into v_raw_parent from private.portal_navigation_node_v1 node
        where node.node_id='geo:' || lower(split_part(v_geography,'-',1)||'-'||split_part(v_geography,'-',2))
          and node.parent_node_id='geo:cn';
      end if;
      v_raw_parent := coalesce(v_raw_parent,'geo:unmapped');
      v_node := private.portal_navigation_raw_node_id_v1('geo', v_geography);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_parent, pg_catalog.upper(v_geography), 'unmapped', 'geography',
        null, null,
        pg_catalog.jsonb_build_object(
          'en', pg_catalog.upper(v_geography), 'zh-CN', pg_catalog.upper(v_geography),
          'de', pg_catalog.upper(v_geography), 'fr', pg_catalog.upper(v_geography)
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
  else
    perform private.portal_navigation_ensure_virtual_v1(
      'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
    );
    v_node := 'geo:unmapped';
  end if;
  v_placements := pg_catalog.array_append(v_placements, v_node);

  -- Materialise every ancestor of every authored placement, so a branch count is
  -- one grouped read instead of a per-node descendant search. A closure row is
  -- `direct` only when the authored placement is exactly that node.
  with recursive ancestors as (
    select n.node_id as leaf,n.parent_node_id as ancestor
    from private.portal_navigation_node_v1 n where n.node_id=any(v_placements)
    union all
    select a.leaf,n.parent_node_id from ancestors a
    join private.portal_navigation_node_v1 n on n.node_id=a.ancestor
    where a.ancestor is not null
  ) select coalesce(array_agg(distinct placement), '{}'::text[]) into v_placements
    from unnest(v_placements) placement
    where not exists(select 1 from ancestors a where a.ancestor=placement);

  foreach v_placement in array v_placements
  loop
    insert into private.portal_navigation_membership_v1 (
      dataset_kind, id, version, dimension, node_id, direct
    )
    with recursive chain as (
      select node.node_id,
        node.parent_node_id,
        node.dimension
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_placement
      union all
      select parent.node_id,
        parent.parent_node_id,
        parent.dimension
      from private.portal_navigation_node_v1 as parent
      join chain on parent.node_id = chain.parent_node_id
    )
    select p_kind, p_id, p_version, chain.dimension, chain.node_id,
      chain.node_id = v_placement
    from chain
    on conflict (dataset_kind,id,version,dimension,node_id) do update
      set direct=private.portal_navigation_membership_v1.direct or excluded.direct;
  end loop;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Writer: the membership projection is maintained next to the public-card row
-- in the same statement, so a retraction or a state change can never leave a
-- stale branch count behind.
-- ---------------------------------------------------------------------------

create function private.sync_portal_navigation_row_v1()
returns trigger language plpgsql volatile security definer
set search_path='' set row_security='on'
as $function$
begin
  if tg_op='DELETE' then
    delete from private.portal_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
    return old;
  end if;
  if tg_op='UPDATE' and (old.dataset_kind,old.id,old.version) is distinct from (new.dataset_kind,new.id,new.version) then
    delete from private.portal_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
  end if;
  perform private.sync_portal_navigation_membership_v1(new.dataset_kind,new.id,new.version,new.card);
  return new;
end;
$function$;

-- `postgres` runs the projection writer and the backfill; every browser-facing
-- role is explicitly revoked because a new function still carries PUBLIC's
-- default execute grant until it is taken away.
revoke all on function private.sync_portal_navigation_membership_v1(text, uuid, text, jsonb)
  from public, anon, authenticated, service_role, portal_public_executor;

comment on function private.sync_portal_navigation_membership_v1(text, uuid, text, jsonb) is
  'Rebuilds one public version''s navigation placements from its already public-safe Portal card; unknown or ambiguous authored codes are retained as their own nodes.';

-- Existing populated parents are backfilled by separate bounded migrations.
grant execute on function private.sync_portal_navigation_membership_v1(text,uuid,text,jsonb) to postgres;
reset role;
create trigger portal_navigation_flow_sync_v1
  after insert or update of card on private.portal_catalog_search_rows_v1
  for each row when (new.dataset_kind='flow') execute function private.sync_portal_navigation_row_v1();
create trigger portal_navigation_process_sync_v1
  after insert or delete or update of card on private.portal_catalog_search_rows_v2
  for each row execute function private.sync_portal_navigation_row_v1();
-- No source-table trigger and no new raw-card derivation. Deletion cascades
-- through the pre-existing V1 public projection, then through the narrow row.
revoke all on function private.sync_portal_navigation_row_v1() from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_classification_code_v1(jsonb) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_classification_label_v1(jsonb) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_geography_code_v1(text,jsonb) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_classification_taxonomy_v1(jsonb) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_resolve_classification_v1(text,jsonb,jsonb,integer) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_resolve_alias_v1(text,text) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_raw_node_id_v1(text,text) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_raw_taxonomy_v1(jsonb) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_virtual_labels_v1(text) from public,anon,authenticated,service_role,portal_public_executor;
revoke all on function private.portal_navigation_ensure_virtual_v1(text,text,text,text) from public,anon,authenticated,service_role,portal_public_executor;
revoke create on schema private from api_internal_executor;
revoke api_internal_executor from postgres;
commit;
