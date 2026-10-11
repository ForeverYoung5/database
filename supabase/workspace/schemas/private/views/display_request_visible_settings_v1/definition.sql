CREATE OR REPLACE VIEW "private"."display_request_visible_settings_v1" WITH ("security_barrier"='true') AS
 SELECT "dataset_kind",
    "dataset_id",
    "dataset_version"
   FROM "private"."dataset_display_settings" "s"
  WHERE ("is_visible" AND ((( SELECT "current_setting"('portal.display_global'::"text", true) AS "current_setting") = 'true'::"text") OR ("brand" = ANY (( SELECT "string_to_array"("current_setting"('portal.display_brands'::"text", true), ','::"text") AS "string_to_array")::"text"[]))) AND ((( SELECT NULLIF("current_setting"('portal.display_filter_brand'::"text", true), ''::"text") AS "nullif") IS NULL) OR ("brand" = ( SELECT "current_setting"('portal.display_filter_brand'::"text", true) AS "current_setting"))));

ALTER VIEW "private"."display_request_visible_settings_v1" OWNER TO "postgres";
