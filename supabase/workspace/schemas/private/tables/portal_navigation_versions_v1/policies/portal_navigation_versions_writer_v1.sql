CREATE POLICY "portal_navigation_versions_writer_v1" ON "private"."portal_navigation_versions_v1" TO "api_internal_executor" USING (true) WITH CHECK (true);
