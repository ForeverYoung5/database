CREATE INDEX "portal_navigation_node_parent_v1_idx" ON "private"."portal_navigation_node_v1" USING "btree" ("dimension", "parent_node_id", "node_id");
