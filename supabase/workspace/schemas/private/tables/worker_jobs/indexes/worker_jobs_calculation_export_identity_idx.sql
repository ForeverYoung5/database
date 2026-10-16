CREATE INDEX "worker_jobs_calculation_export_identity_idx" ON "private"."worker_jobs" USING "btree" ("concurrency_key", "created_at" DESC, "id") WHERE ("job_kind" = 'lca.calculation_export'::"text");
