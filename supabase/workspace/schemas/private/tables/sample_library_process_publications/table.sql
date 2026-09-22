CREATE TABLE IF NOT EXISTS "private"."sample_library_process_publications" (
    "process_id" "uuid" NOT NULL,
    "process_version" character(9) NOT NULL,
    "published_by" "uuid" NOT NULL,
    "published_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "private"."sample_library_process_publications" OWNER TO "postgres";

ALTER TABLE ONLY "private"."sample_library_process_publications"
    ADD CONSTRAINT "sample_library_process_publications_pkey" PRIMARY KEY ("process_id", "process_version");

ALTER TABLE ONLY "private"."sample_library_process_publications"
    ADD CONSTRAINT "sample_library_process_publications_process_fkey" FOREIGN KEY ("process_id", "process_version") REFERENCES "public"."processes"("id", "version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."sample_library_process_publications" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."sample_library_process_publications" TO "api_internal_executor";
