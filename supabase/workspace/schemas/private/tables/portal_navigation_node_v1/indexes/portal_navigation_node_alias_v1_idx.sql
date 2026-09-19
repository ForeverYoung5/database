CREATE INDEX "portal_navigation_node_alias_v1_idx" ON "private"."portal_navigation_node_v1" USING "gin" ("alias_codes") WHERE ("cardinality"("alias_codes") > 0);
