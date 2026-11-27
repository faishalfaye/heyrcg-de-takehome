#!/usr/bin/env python3
"""
fingerprint.py LABEL [DATASET_SUFFIX]: fingerprint every mart table and save it to
evidence/fingerprint_LABEL.csv.

  fp_full    = XOR of FARM_FINGERPRINT(whole row as JSON), audit columns included.
               Equal fp_full on two runs = the table was not rewritten at all.
               Use it for "run 1 vs run 2" (idempotency).
  fp_content = the same without created_at, updated_at, source_file, source_row.
               Use it to compare two DIFFERENT environments (e.g. in-order vs
               out-of-order loading), where load times and file names differ.

    python3 scripts/fingerprint.py after_run1
    python3 scripts/fingerprint.py after_run2
    python3 scripts/fingerprint.py --compare after_run1 after_run2     # prints IDEMPOTENT or the diff
"""
import csv
import os
import sys
from pathlib import Path

from google.cloud import bigquery

TABLES = [
    "heyrcg_mart.dim_customer",
    "heyrcg_mart.dim_hotel",
    "heyrcg_mart.dim_date",
    "heyrcg_mart.fact_bookings",
    "heyrcg_mart.fact_pos_transactions",
    "heyrcg_audit.etl_watermark",
    "heyrcg_audit.customer_change_log",
]
EVIDENCE = Path("evidence")


def fingerprint_sql(project, table, suffix):
    dataset, name = table.split(".")
    return f"""
SELECT '{table}' AS table_name, COUNT(*) AS row_count,
  BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS fp_full,
  BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(JSON_REMOVE(TO_JSON(t),
    '$.created_at', '$.updated_at', '$.source_file', '$.source_row')))) AS fp_content
FROM `{project}.{dataset}{suffix}.{name}` AS t"""


def take(label, suffix):
    project = os.environ.get("PROJECT_ID") or sys.exit("Set PROJECT_ID")
    client = bigquery.Client(project=project, location=os.environ.get("LOCATION", "asia-southeast2"))
    sql = "\nUNION ALL\n".join(fingerprint_sql(project, t, suffix) for t in TABLES) + "\nORDER BY table_name"
    rows = list(client.query(sql).result())
    EVIDENCE.mkdir(exist_ok=True)
    out = EVIDENCE / f"fingerprint_{label}.csv"
    with open(out, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["table_name", "row_count", "fp_full", "fp_content"])
        for r in rows:
            writer.writerow([r.table_name, r.row_count, r.fp_full, r.fp_content])
    print(f"Saved {out}")
    print(out.read_text())


def compare(label_a, label_b):
    a = (EVIDENCE / f"fingerprint_{label_a}.csv").read_text().splitlines()
    b = (EVIDENCE / f"fingerprint_{label_b}.csv").read_text().splitlines()
    if a == b:
        print(f"IDEMPOTENT: {label_b} is identical to {label_a} for every mart table")
        return 0
    print(f"DIFFERENT: {label_a} vs {label_b}")
    for line_a, line_b in zip(a, b):
        if line_a != line_b:
            print(f"  {label_a}: {line_a}\n  {label_b}: {line_b}")
    return 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "--compare":
        sys.exit(compare(args[1], args[2]))
    if len(args) not in (1, 2):
        sys.exit(__doc__)
    take(args[0], f"_{args[1]}" if len(args) == 2 else "")
