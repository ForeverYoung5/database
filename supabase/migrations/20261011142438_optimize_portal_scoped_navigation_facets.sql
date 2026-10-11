-- Database #829: evaluate request-scope settings once per SQL statement and
-- avoid repeated GUC reads and array parsing for every settings row.
-- Preserve the security barrier, RLS, exact keys, DTOs and eight-second budgets.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
select private.portal_display_assert_contract_v1();

create or replace view private.display_request_visible_settings_v1 with (security_barrier=true) as
select s.dataset_kind,s.dataset_id,s.dataset_version
from private.dataset_display_settings s
where s.is_visible and
 ((select current_setting('portal.display_global',true))='true' or
 s.brand=any((select string_to_array(current_setting('portal.display_brands',true),','))::text[]))
and ((select nullif(current_setting('portal.display_filter_brand',true),'')) is null or
 s.brand=(select current_setting('portal.display_filter_brand',true)));

update private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1() where singleton;
select private.portal_display_assert_contract_v1();
notify pgrst,'reload schema';
commit;
