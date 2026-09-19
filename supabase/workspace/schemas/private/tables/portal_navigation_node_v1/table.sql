CREATE TABLE IF NOT EXISTS "private"."portal_navigation_node_v1" (
    "node_id" "text" NOT NULL,
    "parent_node_id" "text",
    "code" "text" NOT NULL,
    "taxonomy" "text" NOT NULL,
    "dimension" "text" NOT NULL,
    "source_index_path" "text",
    "source_file" "text",
    "alias_codes" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "labels" "jsonb" NOT NULL,
    "label_strategy" "jsonb" NOT NULL,
    CONSTRAINT "portal_navigation_node_root_v1_chk" CHECK (("parent_node_id" IS DISTINCT FROM "node_id")),
    CONSTRAINT "portal_navigation_node_v1_code_check" CHECK (("length"("code") >= 1)),
    CONSTRAINT "portal_navigation_node_v1_dimension_check" CHECK (("dimension" = ANY (ARRAY['classification'::"text", 'geography'::"text"]))),
    CONSTRAINT "portal_navigation_node_v1_label_strategy_check" CHECK ((("jsonb_typeof"("label_strategy") = 'object'::"text") AND ("jsonb_typeof"(("label_strategy" -> 'en'::"text")) = 'string'::"text") AND ("jsonb_typeof"(("label_strategy" -> 'zh-CN'::"text")) = 'string'::"text") AND ("jsonb_typeof"(("label_strategy" -> 'de'::"text")) = 'string'::"text") AND ("jsonb_typeof"(("label_strategy" -> 'fr'::"text")) = 'string'::"text"))),
    CONSTRAINT "portal_navigation_node_v1_labels_check" CHECK ((("jsonb_typeof"("labels") = 'object'::"text") AND ("jsonb_typeof"(("labels" -> 'en'::"text")) = 'string'::"text") AND ("jsonb_typeof"(("labels" -> 'zh-CN'::"text")) = 'string'::"text") AND ("jsonb_typeof"(("labels" -> 'de'::"text")) = 'string'::"text") AND ("jsonb_typeof"(("labels" -> 'fr'::"text")) = 'string'::"text"))),
    CONSTRAINT "portal_navigation_node_v1_node_id_check" CHECK (("node_id" ~ '^[a-z][a-z0-9-]*:[!-~]{1,96}$'::"text")),
    CONSTRAINT "portal_navigation_node_v1_taxonomy_check" CHECK (("taxonomy" ~ '^[a-z][a-z0-9-]{1,48}$'::"text"))
);

ALTER TABLE ONLY "private"."portal_navigation_node_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."portal_navigation_node_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_navigation_node_v1"
    ADD CONSTRAINT "portal_navigation_node_v1_pkey" PRIMARY KEY ("node_id");

ALTER TABLE ONLY "private"."portal_navigation_node_v1"
    ADD CONSTRAINT "portal_navigation_node_v1_parent_node_id_fkey" FOREIGN KEY ("parent_node_id") REFERENCES "private"."portal_navigation_node_v1"("node_id") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."portal_navigation_node_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "private"."portal_navigation_node_v1" TO "api_internal_executor";

GRANT SELECT("node_id") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("parent_node_id") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("code") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("taxonomy") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("dimension") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("source_index_path") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("source_file") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("alias_codes") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("labels") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";

GRANT SELECT("label_strategy") ON TABLE "private"."portal_navigation_node_v1" TO "portal_public_executor";
