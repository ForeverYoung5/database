CREATE POLICY "portal_navigation_node_internal_all_v1" ON "private"."portal_navigation_node_v1" TO "api_internal_executor" USING (true) WITH CHECK (true);
