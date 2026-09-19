CREATE INDEX "portal_navigation_node_taxonomy_v1_idx" ON "private"."portal_navigation_node_v1" USING "btree" ("dimension", "taxonomy", "lower"("code")) WHERE ("source_file" IS NOT NULL);
