CREATE TABLE IF NOT EXISTS "private"."open_data_process_publications" (
    "process_id" "uuid" NOT NULL,
    "process_version" character(9) NOT NULL,
    "published_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "published_by" "uuid" NOT NULL
);

ALTER TABLE "private"."open_data_process_publications" OWNER TO "postgres";

COMMENT ON TABLE "private"."open_data_process_publications" IS 'Exact Process versions explicitly published in the Open Data catalog. Row existence is the publication state.';

ALTER TABLE ONLY "private"."open_data_process_publications"
    ADD CONSTRAINT "open_data_process_publications_pkey" PRIMARY KEY ("process_id", "process_version");

ALTER TABLE ONLY "private"."open_data_process_publications"
    ADD CONSTRAINT "open_data_process_publications_process_fkey" FOREIGN KEY ("process_id", "process_version") REFERENCES "public"."processes"("id", "version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."open_data_process_publications" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."open_data_process_publications" TO "api_internal_executor";
