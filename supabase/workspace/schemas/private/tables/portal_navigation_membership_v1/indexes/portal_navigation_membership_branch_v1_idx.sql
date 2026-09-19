CREATE INDEX "portal_navigation_membership_branch_v1_idx" ON "private"."portal_navigation_membership_v1" USING "btree" ("dimension", "node_id", "dataset_kind", "id", "version") INCLUDE ("direct");
