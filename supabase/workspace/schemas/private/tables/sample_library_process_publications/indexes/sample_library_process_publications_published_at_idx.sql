CREATE INDEX "sample_library_process_publications_published_at_idx" ON "private"."sample_library_process_publications" USING "btree" ("published_at" DESC, "process_id", "process_version");
