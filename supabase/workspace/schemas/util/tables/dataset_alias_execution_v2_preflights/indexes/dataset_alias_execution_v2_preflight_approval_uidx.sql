CREATE UNIQUE INDEX "dataset_alias_execution_v2_preflight_approval_uidx" ON "util"."dataset_alias_execution_v2_preflights" USING "btree" ("actor_user_id", "approval_identity_sha256");
