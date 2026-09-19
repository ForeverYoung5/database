CREATE POLICY "portal_navigation_node_portal_select_v1" ON "private"."portal_navigation_node_v1" FOR SELECT TO "portal_public_executor" USING (true);
