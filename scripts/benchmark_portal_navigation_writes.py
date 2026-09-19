#!/usr/bin/env python3
"""Compare original/new projection writer costs in rollback-only local fixtures."""
from __future__ import annotations
import argparse,json,re,subprocess
from pathlib import Path
from benchmark_portal_summary_bounded import run
ROOT=Path(__file__).resolve().parents[1]

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--container',required=True);p.add_argument('--rows',type=int,default=200);p.add_argument('--rounds',type=int,default=3);p.add_argument('--report',type=Path,required=True);a=p.parse_args()
 if not re.fullmatch(r'supabase_db_[a-z0-9-]+',a.container) or not 1<=a.rows<=1000 or not 1<=a.rounds<=5:p.error('Local fixture bounds exceeded')
 context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
 if not context['Endpoints']['docker']['Host'].startswith('unix://'):p.error('Local Docker socket required')
 check=run(a.container,'select inet_server_addr() is null; select count(*) from private.portal_catalog_search_rows_v1;')
 if check.returncode or check.stdout.strip().splitlines()!=['t','0']:p.error('Empty local public projection required')
 helper=re.search(r'create function pg_temp.nav_payload.*?\$\$;', (ROOT/'supabase/tests/20260919_portal_navigation_v1.sql').read_text(),re.S).group()
 rows=[]
 for iteration in range(a.rounds):
  for enabled in [False,True]:
   sql="begin; set local statement_timeout='60s'; grant portal_public_executor,api_internal_executor to postgres;\n"+helper+"\nalter table public.processes disable trigger user; alter table public.processes enable trigger portal_catalog_projection_content_sync_v1; alter table public.processes enable trigger portal_catalog_projection_content_sync_v2;\n"
   if not enabled:sql+='alter table private.portal_catalog_search_rows_v2 disable trigger portal_navigation_process_sync_v1;\n'
   sql+=f"select clock_timestamp() as started \\gset\ninsert into public.processes(id,version,json,state_code,modified_at) select ('656c0000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.000',pg_temp.nav_payload('WriteBench656','CN-AH-HFE','[{{\"@classId\":\"A\"}},{{\"@classId\":\"01\"}}]'),100,'2026-09-19' from generate_series(1,{a.rows}) i;\nset constraints all immediate;\nselect jsonb_build_object('ms',extract(epoch from clock_timestamp()-:'started'::timestamptz)*1000);\nrollback;\n"
   x=run(a.container,sql)
   if x.returncode:raise RuntimeError(x.stderr)
   value=next(json.loads(line) for line in x.stdout.splitlines() if line.startswith('{'));value.update({'navigationWriter':enabled,'rows':a.rows,'iteration':iteration});rows.append(value)
 report={'scope':'rollback-only local source inserts; original projection writers enabled; unrelated authoring jobs suppressed only within the transaction','samples':rows}
 a.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
