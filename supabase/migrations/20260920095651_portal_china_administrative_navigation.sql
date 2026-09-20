-- Portal navigation hierarchy revision (china-administrative-parents-v1).
--
-- Source of truth: data/portal-navigation-china-administrative.json (reviewed GeoAtlas parent evidence)
--   asset sha256 f3af2988ce1fc4c5c6d6c65404a48e44905481476609350e65cb005d6da7da48
--   seed  sha256 53b26ce520f905b770716b065a0c3fdb0bd72c36e76938c61f0dca79f0a15383
--   nodes 6131 (unchanged: this revision re-parents existing rows only)
--   prior asset sha256 3f6481fce115bb29a7af6fe738bc9a9c6d7e4b663f7add95b2bf0c1905661b16
--   prior seed  sha256 62f0c6d7214d6db2bc75d065d71a774e6cefb4f560ca8357866bcd58944027bd
-- Regenerate with:
--   python3 scripts/generate_portal_navigation_vocabulary.py
-- Never edit these rows by hand. This migration never reseeds the vocabulary: the
-- historical bootstrap migration keeps the exact bytes that were applied.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $portal_china_revision_prior_state$
declare
  v_unparented integer;
begin
  select count(*)
  into v_unparented
  from private.portal_navigation_node_v1 as node
  where node.node_id in ('geo:tw', 'geo:hk', 'geo:mo');

  if v_unparented <> 3 then
    raise exception 'Portal China revision expected 3 seeded rows, found %', v_unparented
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from private.portal_navigation_node_v1 as node
    join (values ('geo:tw', 'TW'), ('geo:hk', 'HK'), ('geo:mo', 'MO')) as expected(node_id, code) using (node_id)
    where node.node_id in ('geo:tw', 'geo:hk', 'geo:mo')
      and (node.parent_node_id is not null
        or node.dimension <> 'geography'
        or node.code <> expected.code
        or node.taxonomy <> 'ilcd-locations'
        or node.source_file is null)
  ) then
    raise exception 'Portal China revision prior state is not the reviewed unparented state'
      using errcode = '55000';
  end if;

  if not exists (
    select 1 from private.portal_navigation_node_v1 as node
    where node.node_id = 'geo:cn' and node.code = 'CN'
      and node.dimension = 'geography' and node.taxonomy = 'ilcd-locations'
      and node.parent_node_id is null
  ) then
    raise exception 'Portal China revision needs the country node %', 'geo:cn'
      using errcode = '55000';
  end if;

  if (
    select contract.asset_sha256
    from private.portal_navigation_contract_v1 as contract
    where contract.contract_version = 1
  ) is distinct from '3f6481fce115bb29a7af6fe738bc9a9c6d7e4b663f7add95b2bf0c1905661b16'
     or (
    select contract.seed_sha256
    from private.portal_navigation_contract_v1 as contract
    where contract.contract_version = 1
  ) is distinct from '62f0c6d7214d6db2bc75d065d71a774e6cefb4f560ca8357866bcd58944027bd' then
    raise exception 'Portal navigation contract is not the revision baseline'
      using errcode = '55000';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_trigger
    where tgrelid = 'private.portal_navigation_node_v1'::regclass
      and tgname = 'portal_navigation_seed_guard_v1' and tgenabled = 'O'
      and tgfoid = 'private.guard_portal_navigation_seed_v1()'::regprocedure
  ) then
    raise exception 'Portal navigation seed guard is not enabled as expected'
      using errcode = '55000';
  end if;
end;
$portal_china_revision_prior_state$;

-- Drain the projection writers before touching the hierarchy they read.
-- `private.sync_portal_navigation_membership_v1` upserts this narrow table before
-- it reads node parents, so this lock ordering lets existing writers finish and
-- holds new ones for the rest of the transaction. Reads are unaffected.
lock table private.portal_navigation_versions_v1 in share row exclusive mode;

-- The seeded vocabulary is immutable; this revision is the deliberate exception,
-- so the guard is disabled inside this transaction only and restored before commit.
alter table private.portal_navigation_node_v1 disable trigger portal_navigation_seed_guard_v1;

update private.portal_navigation_node_v1 as node
   set parent_node_id = 'geo:cn'
 where node.node_id in ('geo:tw', 'geo:hk', 'geo:mo')
   and node.parent_node_id is null;

alter table private.portal_navigation_node_v1 enable trigger portal_navigation_seed_guard_v1;

-- Closure refresh: an existing membership of a moved node gains the country
-- ancestor in one set-based, deduplicated insert. `direct` stays false for the new
-- ancestor, and `on conflict do nothing` preserves both an existing row's flag and
-- the unique (dataset_kind, id, version, dimension, node_id) key.
insert into private.portal_navigation_membership_v1 as membership (
  dataset_kind, id, version, dimension, node_id, direct
)
select distinct member.dataset_kind, member.id, member.version, 'geography', 'geo:cn', false
  from private.portal_navigation_membership_v1 as member
 where member.dimension = 'geography' and member.node_id in ('geo:tw', 'geo:hk', 'geo:mo')
on conflict (dataset_kind, id, version, dimension, node_id) do nothing;

-- The manifest row now describes the revised vocabulary.
update private.portal_navigation_contract_v1 as contract
   set asset_sha256 = 'f3af2988ce1fc4c5c6d6c65404a48e44905481476609350e65cb005d6da7da48',
       seed_sha256 = '53b26ce520f905b770716b065a0c3fdb0bd72c36e76938c61f0dca79f0a15383'
 where contract.contract_version = 1;

do $portal_china_revision_readback$
declare
  v_parented integer;
  v_members integer;
begin
  select count(*)
  into v_parented
  from private.portal_navigation_node_v1 as node
  where node.node_id in ('geo:tw', 'geo:hk', 'geo:mo')
    and node.parent_node_id = 'geo:cn';

  if v_parented <> 3 then
    raise exception 'Portal China revision did not parent every reviewed row: %', v_parented
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from private.portal_navigation_membership_v1 as member
    where member.dimension = 'geography' and member.node_id in ('geo:tw', 'geo:hk', 'geo:mo')
      and not exists (
        select 1
        from private.portal_navigation_membership_v1 as ancestor
        where ancestor.dataset_kind = member.dataset_kind
          and ancestor.id = member.id
          and ancestor.version = member.version
          and ancestor.dimension = 'geography'
          and ancestor.node_id = 'geo:cn'
      )
  ) then
    raise exception 'Portal China revision left a membership without its country ancestor'
      using errcode = '55000';
  end if;

  select count(*)
  into v_members
  from private.portal_navigation_membership_v1 as member
  where member.dimension = 'geography' and member.node_id = 'geo:cn';

  if not exists (
    select 1 from pg_catalog.pg_trigger
    where tgrelid = 'private.portal_navigation_node_v1'::regclass
      and tgname = 'portal_navigation_seed_guard_v1' and tgenabled = 'O'
      and tgfoid = 'private.guard_portal_navigation_seed_v1()'::regprocedure
  ) then
    raise exception 'Portal navigation seed guard was not restored'
      using errcode = '55000';
  end if;

  perform private.assert_portal_navigation_contract_v1();
  raise notice 'Portal China revision applied: % rows re-parented, % country memberships',
    v_parented, v_members;
end;
$portal_china_revision_readback$;

commit;
