CREATE POLICY "portal_navigation_contract_internal_select_v1" ON "private"."portal_navigation_contract_v1" FOR SELECT TO "api_internal_executor" USING (("contract_version" = 1));
