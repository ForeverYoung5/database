CREATE POLICY "portal_navigation_contract_reader_v1" ON "private"."portal_navigation_contract_v1" FOR SELECT TO "portal_public_executor" USING (("contract_version" = 1));
