CREATE POLICY "portal_navigation_versions_read_v1" ON "private"."portal_navigation_versions_v1" FOR SELECT TO "portal_public_executor" USING (true);
