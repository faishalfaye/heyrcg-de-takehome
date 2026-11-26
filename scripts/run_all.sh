#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_all.sh: the whole story in one command, with evidence saved to evidence/.
#   load initial files -> initial build -> load delta -> incremental run 1 -> run 2
#   -> fingerprints + before/after revenue + run log.
#
# Needs: bq CLI (gcloud auth login), Dataform CLI (npm i -g @dataform/cli@3.1.8)
# and .df-credentials.json (create it with: dataform init-creds). PROJECT_ID must also be
# set as defaultProject in workflow_settings.yaml.
# If you use the Dataform UI instead, do the same steps by hand: README.md "How to run".
# -----------------------------------------------------------------------------
set -euo pipefail
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID}"
LOCATION="${LOCATION:-asia-southeast2}"
BQ="bq --quiet --headless --project_id=${PROJECT_ID} --location=${LOCATION}"
mkdir -p evidence
q() { $BQ query --use_legacy_sql=false --format=pretty "$1"; }

REVENUE_SQL="SELECT year_month, hotel_name, room_revenue_idr, fnb_revenue_idr, total_revenue_idr
FROM \`${PROJECT_ID}.heyrcg_mart.rpt_monthly_revenue_by_hotel\` WHERE year_month = '2024-03' ORDER BY hotel_name"

echo "== 1. Load the initial files";            ./scripts/load_raw.sh
echo "== 2. Initial build";                     dataform run --tags initial
q "$REVENUE_SQL" | tee evidence/march_revenue_before_increment.txt
echo "== 3. Load the delta files";              ./scripts/load_raw.sh data/delta_customers_2024-04-01.csv data/delta_bookings_2024-04-01.csv
./scripts/fingerprint.sh before_increment
echo "== 4. Incremental run 1";                 dataform run --tags incremental
./scripts/fingerprint.sh after_run1
q "$REVENUE_SQL" | tee evidence/march_revenue_after_increment.txt
echo "== 5. Incremental run 2 (must change nothing)"; dataform run --tags incremental
./scripts/fingerprint.sh after_run2
echo "== 6. Resend the same delta file (must be skipped)"
./scripts/load_raw.sh data/delta_customers_2024-04-01.csv data/delta_bookings_2024-04-01.csv | tee evidence/resend.txt

q "SELECT * FROM \`${PROJECT_ID}.heyrcg_audit.etl_run_log\` ORDER BY run_ts, source_name" | tee evidence/run_log.txt
q "SELECT source_name, action, reason, COUNT(*) AS n FROM \`${PROJECT_ID}.heyrcg_stg.stg_quarantine\`
   GROUP BY 1, 2, 3 ORDER BY 1, 2, 3" | tee evidence/quarantine_summary.txt

if diff -q evidence/fingerprint_after_run1.csv evidence/fingerprint_after_run2.csv >/dev/null; then
  echo "IDEMPOTENT: run 2 left every mart table byte-for-byte identical" | tee evidence/idempotency_result.txt
else
  echo "NOT IDEMPOTENT: see diff below" | tee evidence/idempotency_result.txt
  diff evidence/fingerprint_after_run1.csv evidence/fingerprint_after_run2.csv | tee -a evidence/idempotency_result.txt
  exit 1
fi
