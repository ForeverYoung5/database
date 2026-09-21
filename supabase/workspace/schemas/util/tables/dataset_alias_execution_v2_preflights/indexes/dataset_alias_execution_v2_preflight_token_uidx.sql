CREATE UNIQUE INDEX "dataset_alias_execution_v2_preflight_token_uidx" ON "util"."dataset_alias_execution_v2_preflights" USING "btree" ("token_sha256");
