CREATE OR REPLACE TRIGGER "zzz_guard_process_result_lifecycle" BEFORE DELETE OR UPDATE ON "public"."processes" FOR EACH ROW EXECUTE FUNCTION "private"."zzz_guard_process_result_lifecycle"();
