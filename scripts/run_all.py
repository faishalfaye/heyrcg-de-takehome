#!/usr/bin/env python3
"""
run_all.py: the whole story in one command, with evidence saved to evidence/.

  load initial files -> initial build -> load delta -> incremental run 1 -> run 2
  -> resend test -> fingerprints, revenue before/after, run log, quarantine summary.

Needs: pip install -r requirements.txt, the Dataform CLI (npm i -g @dataform/cli@3.1.8)
and .df-credentials.json (create it with: dataform init-creds). PROJECT_ID must also be
the defaultProject in workflow_settings.yaml.
Using the Dataform UI instead? Do the same steps by hand: see the README.

    python3 scripts/run_all.py
"""
import csv
import os
import subprocess
import sys
from pathlib import Path

from google.cloud import bigquery

PROJECT = os.environ.get("PROJECT_ID") or sys.exit("Set PROJECT_ID")
LOCATION = os.environ.get("LOCATION", "asia-southeast2")
DELTAS = ["data/delta_customers_2024-04-01.csv", "data/delta_bookings_2024-04-01.csv"]
EVIDENCE = Path("evidence")
client = bigquery.Client(project=PROJECT, location=LOCATION)


def step(title, *command):
    print(f"\n== {title}")
    subprocess.run(command, check=True)


def save_query(file_name, sql):
    """Run a query, save the result as CSV in evidence/ and print it."""
    rows = list(client.query(sql).result())
    out = EVIDENCE / file_name
    with open(out, "w", newline="") as f:
        writer = csv.writer(f)
        if rows:
            writer.writerow(rows[0].keys())
            writer.writerows([list(r.values()) for r in rows])
    print(out.read_text())


EVIDENCE.mkdir(exist_ok=True)
revenue_sql = f"""
SELECT year_month, hotel_name, room_revenue_idr, fnb_revenue_idr, total_revenue_idr
FROM `{PROJECT}.heyrcg_mart.rpt_monthly_revenue_by_hotel`
WHERE year_month = '2024-03' ORDER BY hotel_name"""

step("1. Load the initial files", sys.executable, "scripts/load_raw.py")
step("2. Initial build", "dataform", "run", "--tags", "initial")
save_query("march_revenue_before_increment.csv", revenue_sql)
step("3. Load the delta files", sys.executable, "scripts/load_raw.py", *DELTAS)
step("   fingerprint", sys.executable, "scripts/fingerprint.py", "before_increment")
step("4. Incremental run 1", "dataform", "run", "--tags", "incremental")
step("   fingerprint", sys.executable, "scripts/fingerprint.py", "after_run1")
save_query("march_revenue_after_increment.csv", revenue_sql)
step("5. Incremental run 2 (must change nothing)", "dataform", "run", "--tags", "incremental")
step("   fingerprint", sys.executable, "scripts/fingerprint.py", "after_run2")
print("\n== 6. Resend the same delta files (must be skipped)")
resend = subprocess.run([sys.executable, "scripts/load_raw.py", *DELTAS], check=True, capture_output=True, text=True)
print(resend.stdout)
(EVIDENCE / "resend.txt").write_text(resend.stdout)

save_query("run_log.csv", f"SELECT * FROM `{PROJECT}.heyrcg_audit.etl_run_log` ORDER BY run_ts, source_name")
save_query("quarantine_summary.csv", f"""
SELECT source_name, action, reason, COUNT(*) AS n FROM `{PROJECT}.heyrcg_stg.stg_quarantine`
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3""")

result = subprocess.run([sys.executable, "scripts/fingerprint.py", "--compare", "after_run1", "after_run2"],
                        capture_output=True, text=True)
print(result.stdout)
(EVIDENCE / "idempotency_result.txt").write_text(result.stdout)
sys.exit(result.returncode)
