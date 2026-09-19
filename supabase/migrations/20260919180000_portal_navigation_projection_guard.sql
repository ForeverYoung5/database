-- Literal reviewed fingerprints for the independent navigation derivation.
-- Revalidation never refreshes these literals from the live definitions.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create table private.portal_navigation_projection_contract_v1 (
  routine_identity text primary key,
  definition_sha256 text not null check(definition_sha256 ~ '^[0-9a-f]{64}$'),
  owner_name text not null check(owner_name='api_internal_executor')
);
alter table private.portal_navigation_projection_contract_v1 enable row level security;
alter table private.portal_navigation_projection_contract_v1 force row level security;
create policy navigation_projection_contract_read_v1 on private.portal_navigation_projection_contract_v1
  for select to portal_public_executor using(true);
revoke all on private.portal_navigation_projection_contract_v1 from public,anon,authenticated,service_role,api_internal_executor;
grant select(routine_identity,definition_sha256,owner_name) on private.portal_navigation_projection_contract_v1 to portal_public_executor;
insert into private.portal_navigation_projection_contract_v1 values
('private.portal_navigation_classification_code_v1(jsonb)','94f82fe571360c1566f5b29a9892449b823578ad083000c74e63328f785395a4','api_internal_executor'),
('private.portal_navigation_classification_label_v1(jsonb)','a67cf337bc4fff8dd216171d8573e98fd6882ea8c0110b0da6c2f51dfcd3d83c','api_internal_executor'),
('private.portal_navigation_geography_code_v1(text,jsonb)','132780552481569a729022f046272c75ac617839ba12b5f4f29b3930bbd1f4f1','api_internal_executor'),
('private.portal_navigation_classification_taxonomy_v1(jsonb)','db8a56ca692ee43f70422a81a0b68802d0e6d65397f6c12215bda98be11eacb4','api_internal_executor'),
('private.portal_navigation_resolve_classification_v1(text,jsonb,jsonb,integer)','d86d73a1cbbfdbdb111ddf04cde492c6a4eb99d227ccd3623ffdb28edf3d6f9e','api_internal_executor'),
('private.portal_navigation_resolve_alias_v1(text,text)','77776d2233e9591c2393e0431b6011f3ee4d8dab8a28a57a91a6a0cfcc436ce6','api_internal_executor'),
('private.portal_navigation_raw_node_id_v1(text,text)','e6d1cb1d0b83afdd916d9a51f7397ef4e13c49d51f791ac569876909ca529618','api_internal_executor'),
('private.portal_navigation_raw_taxonomy_v1(jsonb)','e85e389731d717ceb15278cb48386e3905d9d88493e07fd075acf325ab57bbc5','api_internal_executor'),
('private.portal_navigation_virtual_labels_v1(text)','2519626346d6ada888750c4438903b9f6d360aa8903ea6ea0478c0b698b1f80a','api_internal_executor'),
('private.portal_navigation_ensure_virtual_v1(text,text,text,text)','c3b8f6196143a05a4c6f3a87a1adc9de24b8642fd464b1ddec76f7dfca9a01da','api_internal_executor'),
('private.sync_portal_navigation_membership_v1(text,uuid,text,jsonb)','1c255e966cdaccf2bd2d4fb235338720183d7afb80077512141600362051f9d9','api_internal_executor'),
('private.sync_portal_navigation_row_v1()','119321bd14c90a79cf23cd1cfe3dc5a6b67f5c86e36d3d7d8b3d791a804a39ae','api_internal_executor');

grant portal_public_executor,api_internal_executor to postgres;
grant create on schema private to portal_public_executor,api_internal_executor;
create function private.assert_portal_navigation_projection_v1() returns void
language plpgsql stable security definer set search_path='' set row_security='on'
as $function$
declare e record;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();
  if (select count(*) from private.portal_navigation_projection_contract_v1)<>12 then
    raise exception 'Portal navigation derivation contract is absent' using errcode='55000';
  end if;
  for e in select * from private.portal_navigation_projection_contract_v1 loop
    if to_regprocedure(e.routine_identity) is null or not exists(
      select 1 from pg_proc p where p.oid=to_regprocedure(e.routine_identity)
      and pg_get_userbyid(p.proowner)=e.owner_name
      and encode(extensions.digest(convert_to(pg_get_functiondef(p.oid),'UTF8'),'sha256'),'hex')=e.definition_sha256
    ) then raise exception 'Portal navigation derivation contract drifted' using errcode='55000'; end if;
  end loop;
  if (select count(*) from pg_class c where c.oid in (
      'private.portal_navigation_versions_v1'::regclass,'private.portal_navigation_membership_v1'::regclass)
      and c.relrowsecurity and c.relforcerowsecurity and pg_get_userbyid(c.relowner)='postgres')<>2
    or (select count(*) from pg_constraint c where c.contype='f' and c.convalidated and c.confdeltype='c'
      and ((c.conrelid='private.portal_navigation_versions_v1'::regclass and c.confrelid in (
        'private.portal_catalog_search_rows_v1'::regclass,'private.portal_catalog_search_rows_v2'::regclass))
        or (c.conrelid='private.portal_navigation_membership_v1'::regclass and c.confrelid='private.portal_navigation_versions_v1'::regclass)))<>3
    or not exists(select 1 from pg_trigger t where t.tgrelid='private.portal_catalog_search_rows_v1'::regclass
      and t.tgname='portal_navigation_flow_sync_v1' and t.tgenabled='O' and t.tgtype=21 and t.tgattr::text='6' and not t.tgdeferrable and not t.tginitdeferred and t.tgfoid='private.sync_portal_navigation_row_v1()'::regprocedure)
    or not exists(select 1 from pg_trigger t where t.tgrelid='private.portal_catalog_search_rows_v2'::regclass
      and t.tgname='portal_navigation_process_sync_v1' and t.tgenabled='O' and t.tgtype=29 and t.tgattr::text='6' and not t.tgdeferrable and not t.tginitdeferred and t.tgfoid='private.sync_portal_navigation_row_v1()'::regprocedure)
  then raise exception 'Portal navigation projection boundary drifted' using errcode='55000'; end if;
end;
$function$;
alter function private.assert_portal_navigation_projection_v1() owner to portal_public_executor;
revoke all on function private.assert_portal_navigation_projection_v1() from public,anon,authenticated,service_role;
grant execute on function private.assert_portal_navigation_projection_v1() to portal_public_executor,api_internal_executor;
select private.assert_portal_navigation_projection_v1();

-- Runtime writers may create unknown nodes, but cannot rewrite reviewed labels,
-- aliases or hierarchy. A reviewed vocabulary migration must deliberately replace
-- this guard before replacing the seeded vocabulary.
create function private.guard_portal_navigation_seed_v1() returns trigger
language plpgsql set search_path='' as $function$
begin
  -- Every node identity is immutable, including runtime virtual/raw nodes.
  -- Source writers only INSERT ... ON CONFLICT DO NOTHING.
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'Seeded navigation vocabulary is immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$function$;
alter function private.guard_portal_navigation_seed_v1() owner to api_internal_executor;
revoke all on function private.guard_portal_navigation_seed_v1() from public,anon,authenticated,service_role;
create trigger portal_navigation_seed_guard_v1 before update or delete on private.portal_navigation_node_v1
  for each row execute function private.guard_portal_navigation_seed_v1();
revoke create on schema private from portal_public_executor,api_internal_executor;
revoke portal_public_executor,api_internal_executor from postgres;
commit;
