CREATE TABLE IF NOT EXISTS "private"."portal_navigation_contract_v1" (
    "contract_version" smallint NOT NULL,
    "manifest_schema" "text" NOT NULL,
    "asset_sha256" "text" NOT NULL,
    "seed_sha256" "text" NOT NULL,
    "node_count" integer NOT NULL,
    "created_by_migration" "text" NOT NULL,
    CONSTRAINT "portal_navigation_contract_asset_v1_chk" CHECK (("asset_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "portal_navigation_contract_count_v1_chk" CHECK ((("node_count" >= 1) AND ("node_count" <= 100000))),
    CONSTRAINT "portal_navigation_contract_migration_v1_chk" CHECK (("created_by_migration" ~ '^[0-9]{14}$'::"text")),
    CONSTRAINT "portal_navigation_contract_schema_v1_chk" CHECK (("manifest_schema" = 'portal.navigation-vocabulary-manifest.v1'::"text")),
    CONSTRAINT "portal_navigation_contract_seed_v1_chk" CHECK (("seed_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "portal_navigation_contract_version_v1_chk" CHECK (("contract_version" = 1))
);

ALTER TABLE ONLY "private"."portal_navigation_contract_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."portal_navigation_contract_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_navigation_contract_v1"
    ADD CONSTRAINT "portal_navigation_contract_v1_pkey" PRIMARY KEY ("contract_version");

ALTER TABLE "private"."portal_navigation_contract_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."portal_navigation_contract_v1" TO "api_internal_executor";

GRANT SELECT("contract_version") ON TABLE "private"."portal_navigation_contract_v1" TO "portal_public_executor";

GRANT SELECT("asset_sha256") ON TABLE "private"."portal_navigation_contract_v1" TO "portal_public_executor";
