#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# load_raw.sh: land source CSV files in BigQuery exactly as they are.
#
#   ./scripts/load_raw.sh                      # load the 4 initial files
#   ./scripts/load_raw.sh data/delta_*.csv     # load the daily delta files
#
# Rules this script follows (see docs/decisions.md D1):
#   * Every source column is loaded as STRING. No autodetect: autodetect would
#     silently "fix" values (drop the leading 0 of phone numbers, guess date
#     formats, turn "IDR 220,000" into NULL). Cleaning happens later, in SQL,
#     where every rule is visible and tested.
#   * Every row gets lineage: _source_file, _source_row (line number in the
#     file) and _loaded_at.
#   * Every file is recorded in heyrcg_raw.file_manifest with its MD5.
#     - same name + same MD5 already loaded  -> skipped (safe resend)
#     - same name + different MD5            -> stop, a human must decide
#   * Loading is idempotent per file: rows of a half-finished earlier attempt
#     for the same file are deleted before the file is loaded again.
# Requires: bq CLI authenticated (gcloud auth login), md5sum, awk.
# -----------------------------------------------------------------------------
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID, e.g. export PROJECT_ID=my-project}"
LOCATION="${LOCATION:-asia-southeast2}"
RAW="${RAW_DATASET:-heyrcg_raw}"
SUFFIX="${DATASET_SUFFIX:-}"      # e.g. _ooo for the out-of-order scenario (docs/decisions.md D11)
LOADED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"   # UTC
BQ="bq --quiet --headless --project_id=${PROJECT_ID} --location=${LOCATION}"

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=(data/raw_customers.csv data/raw_bookings.csv data/raw_pos_transactions.csv data/raw_marketing_performance.csv)
fi

# 1. Datasets (all in the same location, otherwise BigQuery can't join them).
for ds in "${RAW}" "heyrcg_stg${SUFFIX}" "heyrcg_mart${SUFFIX}" "heyrcg_audit${SUFFIX}" "heyrcg_assertions${SUFFIX}"; do
  $BQ show --dataset "${PROJECT_ID}:${ds}" >/dev/null 2>&1 || $BQ mk --dataset "${PROJECT_ID}:${ds}"
done

# 2. Manifest table: one row per file ever loaded. processed_at is filled by the
#    incremental Dataform action once the file's rows have been merged.
$BQ query --use_legacy_sql=false "
CREATE TABLE IF NOT EXISTS \`${PROJECT_ID}.${RAW}.file_manifest\` (
  file_name    STRING    NOT NULL,
  source_name  STRING    NOT NULL,
  file_md5     STRING    NOT NULL,
  row_count    INT64     NOT NULL,
  loaded_at    TIMESTAMP NOT NULL,
  processed_at TIMESTAMP
)" >/dev/null

source_of() {   # map a file name to its raw table
  case "$(basename "$1")" in
    raw_bookings.csv|delta_bookings_*.csv)   echo bookings ;;
    raw_customers.csv|delta_customers_*.csv) echo customers ;;
    raw_pos_transactions.csv)                echo pos_transactions ;;
    raw_marketing_performance.csv)           echo marketing_performance ;;
    *) echo "Unknown file: $1" >&2; exit 1 ;;
  esac
}

for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  src="$(source_of "$f")"
  md5="$(md5sum "$f" | cut -d' ' -f1)"
  rows=$(( $(wc -l < "$f") - 1 ))

  # 3. Resend / conflict check against the manifest.
  seen="$($BQ query --use_legacy_sql=false --format=csv \
    "SELECT COALESCE(STRING_AGG(file_md5), '') FROM \`${PROJECT_ID}.${RAW}.file_manifest\` WHERE file_name = '${name}'" | tail -1)"
  if [ "$seen" = "$md5" ]; then echo "SKIP  ${name}: already loaded (same MD5)"; continue; fi
  if [ -n "$seen" ]; then echo "STOP  ${name}: loaded before with a DIFFERENT MD5 (${seen}). Investigate before reloading." >&2; exit 1; fi

  # 4. Raw table = lineage columns + every source column as STRING.
  #    Bookings/customers always get an updated_at column so the initial file
  #    (no updated_at) and delta files (with updated_at) share one table.
  header="$(head -1 "$f" | tr -d '\r')"
  case "$src" in bookings|customers) [[ "$header" == *",updated_at" ]] || header="${header},updated_at" ;; esac
  schema="_source_file:STRING,_source_row:INT64,_loaded_at:TIMESTAMP"
  IFS=',' read -ra cols <<< "$header"
  for c in "${cols[@]}"; do schema="${schema},${c}:STRING"; done
  $BQ show "${PROJECT_ID}:${RAW}.${src}" >/dev/null 2>&1 || $BQ mk --table "${PROJECT_ID}:${RAW}.${src}" "$schema"

  # 5. Remove leftovers of a failed earlier attempt for this file, then load.
  $BQ query --use_legacy_sql=false \
    "DELETE FROM \`${PROJECT_ID}.${RAW}.${src}\` WHERE _source_file = '${name}'" >/dev/null
  tmp="$(mktemp)"
  # Prefix each line with file name, line number and load time. Values are not touched.
  awk -v n="$name" -v t="$LOADED_AT" 'NR==1 {print "_f,_r,_t," $0; next} {print n "," NR "," t "," $0}' "$f" > "$tmp"
  $BQ load --source_format=CSV --skip_leading_rows=1 --allow_jagged_rows --noautodetect \
    "${PROJECT_ID}:${RAW}.${src}" "$tmp"
  rm -f "$tmp"

  # 6. Verify row count, then record the file in the manifest.
  loaded="$($BQ query --use_legacy_sql=false --format=csv \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.${RAW}.${src}\` WHERE _source_file = '${name}'" | tail -1)"
  if [ "$loaded" != "$rows" ]; then echo "STOP  ${name}: file has ${rows} rows, BigQuery has ${loaded}" >&2; exit 1; fi
  $BQ query --use_legacy_sql=false "
    INSERT INTO \`${PROJECT_ID}.${RAW}.file_manifest\` (file_name, source_name, file_md5, row_count, loaded_at)
    VALUES ('${name}', '${src}', '${md5}', ${rows}, TIMESTAMP '${LOADED_AT}')" >/dev/null
  echo "OK    ${name} -> ${RAW}.${src} (${rows} rows)"
done
