CREATE POLICY "navigation_projection_contract_read_v1" ON "private"."portal_navigation_projection_contract_v1" FOR SELECT TO "portal_public_executor" USING (true);
