CREATE TABLE IF NOT EXISTS "private"."portal_navigation_membership_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "dimension" "text" NOT NULL,
    "node_id" "text" NOT NULL,
    "direct" boolean NOT NULL,
    CONSTRAINT "portal_navigation_membership_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "portal_navigation_membership_v1_dimension_check" CHECK (("dimension" = ANY (ARRAY['classification'::"text", 'geography'::"text"]))),
    CONSTRAINT "portal_navigation_membership_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."portal_navigation_membership_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."portal_navigation_membership_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_navigation_membership_v1"
    ADD CONSTRAINT "portal_navigation_membership_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version", "dimension", "node_id");

ALTER TABLE ONLY "private"."portal_navigation_membership_v1"
    ADD CONSTRAINT "portal_navigation_membership_v1_dataset_kind_id_version_fkey" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."portal_navigation_versions_v1"("dataset_kind", "id", "version") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "private"."portal_navigation_membership_v1"
    ADD CONSTRAINT "portal_navigation_membership_v1_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "private"."portal_navigation_node_v1"("node_id") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."portal_navigation_membership_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "private"."portal_navigation_membership_v1" TO "api_internal_executor";

GRANT SELECT("dataset_kind") ON TABLE "private"."portal_navigation_membership_v1" TO "portal_public_executor";

GRANT SELECT("id") ON TABLE "private"."portal_navigation_membership_v1" TO "portal_public_executor";

GRANT SELECT("version") ON TABLE "private"."portal_navigation_membership_v1" TO "portal_public_executor";

GRANT SELECT("dimension") ON TABLE "private"."portal_navigation_membership_v1" TO "portal_public_executor";

GRANT SELECT("node_id") ON TABLE "private"."portal_navigation_membership_v1" TO "portal_public_executor";

GRANT SELECT("direct") ON TABLE "private"."portal_navigation_membership_v1" TO "portal_public_executor";
