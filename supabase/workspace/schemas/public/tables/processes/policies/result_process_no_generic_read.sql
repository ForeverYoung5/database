CREATE POLICY "result_process_no_generic_read" ON "public"."processes" AS RESTRICTIVE FOR SELECT TO "authenticated", "anon" USING (("state_code" IS DISTINCT FROM 120));
