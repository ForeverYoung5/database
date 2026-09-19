CREATE TABLE IF NOT EXISTS "private"."portal_navigation_projection_contract_v1" (
    "routine_identity" "text" NOT NULL,
    "definition_sha256" "text" NOT NULL,
    "owner_name" "text" NOT NULL,
    CONSTRAINT "portal_navigation_projection_contract_v1_owner_name_check" CHECK (("owner_name" = 'api_internal_executor'::"text")),
    CONSTRAINT "portal_navigation_projection_contract_v_definition_sha256_check" CHECK (("definition_sha256" ~ '^[0-9a-f]{64}$'::"text"))
);

ALTER TABLE ONLY "private"."portal_navigation_projection_contract_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."portal_navigation_projection_contract_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_navigation_projection_contract_v1"
    ADD CONSTRAINT "portal_navigation_projection_contract_v1_pkey" PRIMARY KEY ("routine_identity");

ALTER TABLE "private"."portal_navigation_projection_contract_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT("routine_identity") ON TABLE "private"."portal_navigation_projection_contract_v1" TO "portal_public_executor";

GRANT SELECT("definition_sha256") ON TABLE "private"."portal_navigation_projection_contract_v1" TO "portal_public_executor";

GRANT SELECT("owner_name") ON TABLE "private"."portal_navigation_projection_contract_v1" TO "portal_public_executor";
