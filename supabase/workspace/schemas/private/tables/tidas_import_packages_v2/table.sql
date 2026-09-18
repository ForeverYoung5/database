CREATE TABLE IF NOT EXISTS "private"."tidas_import_packages_v2" (
    "worker_job_id" "uuid" NOT NULL,
    "entries_sha256" "text" NOT NULL,
    "receipt" "jsonb" NOT NULL,
    "committed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tidas_import_packages_v2_entries_sha256_check" CHECK (("entries_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "tidas_import_packages_v2_receipt_check" CHECK (("jsonb_typeof"("receipt") = 'object'::"text"))
);

ALTER TABLE "private"."tidas_import_packages_v2" OWNER TO "postgres";

ALTER TABLE ONLY "private"."tidas_import_packages_v2"
    ADD CONSTRAINT "tidas_import_packages_v2_pkey" PRIMARY KEY ("worker_job_id");

ALTER TABLE ONLY "private"."tidas_import_packages_v2"
    ADD CONSTRAINT "tidas_import_packages_v2_worker_job_id_fkey" FOREIGN KEY ("worker_job_id") REFERENCES "private"."tidas_import_plans_v2"("worker_job_id");

ALTER TABLE "private"."tidas_import_packages_v2" ENABLE ROW LEVEL SECURITY;
