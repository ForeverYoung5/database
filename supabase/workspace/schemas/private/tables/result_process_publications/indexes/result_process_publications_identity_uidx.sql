CREATE UNIQUE INDEX "result_process_publications_identity_uidx" ON "private"."result_process_publications" USING "btree" ("dataset_id", "dataset_version");
