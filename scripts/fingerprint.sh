#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# fingerprint.sh LABEL [DATASET_SUFFIX]
# Takes a fingerprint of every mart table and saves it to evidence/fingerprint_LABEL.csv.
#
#   fp_full    = XOR of FARM_FINGERPRINT(whole row as JSON), audit columns included.
#                Two runs with equal fp_full left the table byte-for-byte identical.
#                Use it for "run 1 vs run 2" (idempotency).
#   fp_content = same, but without created_at, updated_at, source_file, source_row.
#                Use it to compare two DIFFERENT environments, e.g. in-order vs
#                out-of-order loading, where load times and file names differ.
#
#   ./scripts/fingerprint.sh after_run1
#   ./scripts/fingerprint.sh after_run2
#   diff evidence/fingerprint_after_run1.csv evidence/fingerprint_after_run2.csv && echo IDEMPOTENT
# -----------------------------------------------------------------------------
set -euo pipefail
LABEL="${1:?usage: fingerprint.sh LABEL [DATASET_SUFFIX]}"
SUFFIX="${2:-}"; [ -n "$SUFFIX" ] && SUFFIX="_${SUFFIX}"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID}"
LOCATION="${LOCATION:-asia-southeast2}"
mkdir -p evidence

fp() {  # $1 = dataset.table
  cat <<SQL
SELECT '$1' AS table_name, COUNT(*) AS row_count,
  BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS fp_full,
  BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(JSON_REMOVE(TO_JSON(t),
    '\$.created_at', '\$.updated_at', '\$.source_file', '\$.source_row')))) AS fp_content
FROM \`${PROJECT_ID}.$1\` AS t
SQL
}

SQL="$(fp heyrcg_mart${SUFFIX}.dim_customer)
UNION ALL $(fp heyrcg_mart${SUFFIX}.dim_hotel)
UNION ALL $(fp heyrcg_mart${SUFFIX}.dim_date)
UNION ALL $(fp heyrcg_mart${SUFFIX}.fact_bookings)
UNION ALL $(fp heyrcg_mart${SUFFIX}.fact_pos_transactions)
UNION ALL $(fp heyrcg_audit${SUFFIX}.etl_watermark)
UNION ALL $(fp heyrcg_audit${SUFFIX}.customer_change_log)
ORDER BY table_name"

# table names carry the suffix; strip it so files from two environments can be diffed
bq --quiet --headless --project_id="$PROJECT_ID" --location="$LOCATION" query \
  --use_legacy_sql=false --format=csv "$SQL" | sed "s/${SUFFIX:-__no_suffix__}\././g" > "evidence/fingerprint_${LABEL}.csv"
echo "Saved evidence/fingerprint_${LABEL}.csv"
cat "evidence/fingerprint_${LABEL}.csv"
