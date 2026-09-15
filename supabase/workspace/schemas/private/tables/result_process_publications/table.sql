CREATE TABLE IF NOT EXISTS "private"."result_process_publications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "actor_user_id" "uuid" NOT NULL,
    "dataset_id" "uuid" NOT NULL,
    "dataset_version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "role" "text" NOT NULL,
    "target_state" integer NOT NULL,
    "content_sha256" "text" NOT NULL,
    "hash_domain" "text" NOT NULL,
    "source_kind" "text" NOT NULL,
    "candidate_set_hash" "text" NOT NULL,
    "source_manifest_hash" "text" NOT NULL,
    "executable_plan_hash" "text" NOT NULL,
    "approval_hash" "text" NOT NULL,
    "preparation_hash" "text" NOT NULL,
    "idempotency_key" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "request_binding" "jsonb" NOT NULL,
    "published_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "result_process_publications_approval_hash_chk" CHECK (("approval_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "result_process_publications_binding_chk" CHECK (("jsonb_typeof"("request_binding") = 'object'::"text")),
    CONSTRAINT "result_process_publications_candidate_hash_chk" CHECK (("candidate_set_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "result_process_publications_content_hash_chk" CHECK (("content_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "result_process_publications_domain_chk" CHECK (("hash_domain" = 'result-process-content.v1'::"text")),
    CONSTRAINT "result_process_publications_key_chk" CHECK ((("length"("idempotency_key") >= 1) AND ("length"("idempotency_key") <= 200))),
    CONSTRAINT "result_process_publications_manifest_hash_chk" CHECK (("source_manifest_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "result_process_publications_plan_hash_chk" CHECK (("executable_plan_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "result_process_publications_preparation_hash_chk" CHECK (("preparation_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "result_process_publications_reason_chk" CHECK ((("length"("reason") >= 1) AND ("length"("reason") <= 1000))),
    CONSTRAINT "result_process_publications_role_chk" CHECK (("role" = 'result_process'::"text")),
    CONSTRAINT "result_process_publications_source_kind_chk" CHECK (("source_kind" = 'manager_attestation'::"text")),
    CONSTRAINT "result_process_publications_state_chk" CHECK (("state_code" = 120)),
    CONSTRAINT "result_process_publications_target_chk" CHECK (("target_state" = 120)),
    CONSTRAINT "result_process_publications_version_chk" CHECK (("dataset_version" ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'::"text"))
);

ALTER TABLE "private"."result_process_publications" OWNER TO "postgres";

ALTER TABLE ONLY "private"."result_process_publications"
    ADD CONSTRAINT "result_process_publications_pkey" PRIMARY KEY ("id");

GRANT SELECT ON TABLE "private"."result_process_publications" TO "api_internal_executor";
