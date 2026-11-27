#!/usr/bin/env python3
"""
load_raw.py: land source CSV files in BigQuery exactly as they are.

    python3 scripts/load_raw.py                      # the 4 initial files
    python3 scripts/load_raw.py data/delta_*.csv     # the daily delta files

Rules (docs/decisions.md D1):
  * Every source column is loaded as STRING, autodetect off. Autodetect would silently
    "fix" values (drop the leading 0 of phone numbers, guess date formats, turn
    "IDR 220,000" into NULL). Cleaning happens later, in SQL, where every rule is visible.
  * Every row gets lineage: _source_file, _source_row (line number in the file), _loaded_at.
  * Every file is recorded in heyrcg_raw.file_manifest with its MD5:
      - same name + same MD5 already loaded  -> skipped (safe resend)
      - same name + different MD5            -> stop, a human must decide
  * Idempotent per file: rows left by a failed earlier attempt for the same file are
    deleted before the file is loaded again.

Environment: PROJECT_ID (required), LOCATION (default asia-southeast2),
RAW_DATASET (default heyrcg_raw), DATASET_SUFFIX (e.g. _ooo, see decisions.md D11).
Requires: pip install -r requirements.txt, and Google credentials
(Cloud Shell: automatic; laptop: gcloud auth application-default login).
"""
import csv
import hashlib
import io
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import bigquery

INITIAL_FILES = [
    "data/raw_customers.csv",
    "data/raw_bookings.csv",
    "data/raw_pos_transactions.csv",
    "data/raw_marketing_performance.csv",
]
DATAFORM_DATASETS = ["heyrcg_stg", "heyrcg_mart", "heyrcg_audit", "heyrcg_assertions"]


def source_of(file_name: str) -> str:
    """Which raw table a file goes to."""
    if file_name == "raw_bookings.csv" or file_name.startswith("delta_bookings_"):
        return "bookings"
    if file_name == "raw_customers.csv" or file_name.startswith("delta_customers_"):
        return "customers"
    if file_name == "raw_pos_transactions.csv":
        return "pos_transactions"
    if file_name == "raw_marketing_performance.csv":
        return "marketing_performance"
    sys.exit(f"STOP  unknown file: {file_name}")


def run(client, sql, **params):
    """Run one SQL statement with named parameters and return the rows."""
    config = bigquery.QueryJobConfig(query_parameters=[
        bigquery.ScalarQueryParameter(name, "INT64" if isinstance(value, int) else "STRING", value)
        for name, value in params.items()
    ])
    return list(client.query(sql, job_config=config).result())


def main():
    project = os.environ.get("PROJECT_ID") or sys.exit("Set PROJECT_ID, e.g. export PROJECT_ID=my-project")
    location = os.environ.get("LOCATION", "asia-southeast2")
    raw = os.environ.get("RAW_DATASET", "heyrcg_raw")
    suffix = os.environ.get("DATASET_SUFFIX", "")
    files = sys.argv[1:] or INITIAL_FILES
    client = bigquery.Client(project=project, location=location)

    # 1. Datasets, all in one location (BigQuery cannot join across locations).
    for name in [raw] + [d + suffix for d in DATAFORM_DATASETS]:
        dataset = bigquery.Dataset(f"{project}.{name}")
        dataset.location = location
        client.create_dataset(dataset, exists_ok=True)

    # 2. Manifest: one row per file ever loaded. processed_at is set by incremental_load.
    manifest = f"{project}.{raw}.file_manifest"
    run(client, f"""
        CREATE TABLE IF NOT EXISTS `{manifest}` (
          file_name STRING NOT NULL, source_name STRING NOT NULL, file_md5 STRING NOT NULL,
          row_count INT64 NOT NULL, loaded_at TIMESTAMP NOT NULL, processed_at TIMESTAMP)""")

    loaded_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")  # UTC
    for path in map(Path, files):
        load_file(client, project, raw, manifest, path, loaded_at)


def load_file(client, project, raw, manifest, path, loaded_at):
    name = path.name
    source = source_of(name)
    md5 = hashlib.md5(path.read_bytes()).hexdigest()
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows = list(reader)

    # 3. Resend / conflict check against the manifest.
    seen = [r.file_md5 for r in run(client, f"SELECT file_md5 FROM `{manifest}` WHERE file_name = @name", name=name)]
    if md5 in seen:
        print(f"SKIP  {name}: already loaded (same MD5)")
        return
    if seen:
        sys.exit(f"STOP  {name}: loaded before with a DIFFERENT MD5 ({seen[0]}). Investigate before reloading.")

    # 4. Raw table = lineage columns + every source column as STRING. Bookings and customers
    #    always get an updated_at column so the initial file (without it) and the delta files
    #    (with it) share one table. The delta header is the initial header + updated_at.
    if source in ("bookings", "customers") and header[-1] != "updated_at":
        header = header + ["updated_at"]
    schema = [
        bigquery.SchemaField("_source_file", "STRING"),
        bigquery.SchemaField("_source_row", "INT64"),
        bigquery.SchemaField("_loaded_at", "TIMESTAMP"),
    ] + [bigquery.SchemaField(column, "STRING") for column in header]
    table_id = f"{project}.{raw}.{source}"
    table = client.create_table(bigquery.Table(table_id, schema=schema), exists_ok=True)

    # 5. Remove leftovers of a failed earlier attempt for this file, then load.
    run(client, f"DELETE FROM `{table_id}` WHERE _source_file = @name", name=name)
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    for line_number, row in enumerate(rows, start=2):        # line 1 is the header
        writer.writerow([name, line_number, loaded_at] + row)  # values are not touched
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        schema=table.schema,
        autodetect=False,
        allow_jagged_rows=True,          # initial file has one column less (no updated_at)
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
    )
    client.load_table_from_file(io.BytesIO(buffer.getvalue().encode("utf-8")), table_id,
                                job_config=job_config).result()

    # 6. Verify the row count, then record the file in the manifest.
    loaded = run(client, f"SELECT COUNT(*) AS n FROM `{table_id}` WHERE _source_file = @name", name=name)[0].n
    if loaded != len(rows):
        sys.exit(f"STOP  {name}: file has {len(rows)} rows, BigQuery has {loaded}")
    run(client, f"""
        INSERT INTO `{manifest}` (file_name, source_name, file_md5, row_count, loaded_at)
        VALUES (@name, @source, @md5, @rows, TIMESTAMP(@loaded_at))""",
        name=name, source=source, md5=md5, rows=len(rows), loaded_at=loaded_at)
    print(f"OK    {name} -> {raw}.{source} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
