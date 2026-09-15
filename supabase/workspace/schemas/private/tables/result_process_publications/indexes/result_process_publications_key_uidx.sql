CREATE UNIQUE INDEX "result_process_publications_key_uidx" ON "private"."result_process_publications" USING "btree" ("actor_user_id", "idempotency_key");
