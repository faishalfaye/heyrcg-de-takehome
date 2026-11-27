#!/usr/bin/env python3
"""
run_local.py: the whole pipeline on your own machine, no cloud account needed.

    pip install -r local/requirements.txt      # only DuckDB
    python3 local/run_local.py

It runs the same story as scripts/run_all.py does on BigQuery, with the same SQL logic ported
to DuckDB (local/sql/, one file per Dataform folder):

  1. load the 4 initial CSV files into raw tables (all columns as text, lineage, MD5 manifest)
  2. initial build: staging, reference, change log, dimensions, facts, reports + assertions
  3. load the 2024-04-01 delta files
  4. incremental run 1 (one transaction) + assertions
  5. incremental run 2 (must change nothing) + assertions
  6. resend the same delta files (must be skipped by the manifest)
  7. compare every number with the BigQuery run committed in evidence/
  8. compute what each judgement call's alternative would give (README, section Assumptions)

Outputs go to local/output/ (same file names as evidence/). The database is kept at
local/output/heyrcg.duckdb, so you can query it afterwards, e.g.
    python3 -c "import duckdb; print(duckdb.connect('local/output/heyrcg.duckdb').sql('FROM heyrcg_mart.rpt_monthly_revenue_by_hotel'))"

Exit code 0 = every assertion passed, run 2 changed nothing, and every number matches evidence/.
"""
import csv
import hashlib
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

try:
    import duckdb
except ImportError:
    sys.exit("DuckDB is not installed. Run:  pip install -r local/requirements.txt")

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "local" / "sql"
OUT = ROOT / "local" / "output"
EVIDENCE = ROOT / "evidence"
DB_FILE = OUT / "heyrcg.duckdb"

SNAPSHOT_TS = "TIMESTAMP '2024-03-28 00:00:00'"   # same as var snapshot_ts in workflow_settings.yaml
INITIAL_FILES = ["raw_customers.csv", "raw_bookings.csv", "raw_pos_transactions.csv", "raw_marketing_performance.csv"]
DELTA_FILES = ["delta_customers_2024-04-01.csv", "delta_bookings_2024-04-01.csv"]
FINGERPRINT_TABLES = [
    "heyrcg_mart.dim_customer", "heyrcg_mart.dim_hotel", "heyrcg_mart.dim_date",
    "heyrcg_mart.fact_bookings", "heyrcg_mart.fact_pos_transactions",
    "heyrcg_audit.etl_watermark", "heyrcg_audit.customer_change_log",
]
AUDIT_COLUMNS = {"created_at", "updated_at", "source_file", "source_row"}

problems = []   # everything that should make the run fail; printed at the end
skipped = []    # comparisons with evidence/ that could not be made (file missing)


# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------
def say(text=""):
    print(text, flush=True)


def sql_text(file_name, **subs):
    """Read a SQL file and fill in its placeholders."""
    text = (SQL / file_name).read_text(encoding="utf-8")
    subs.setdefault("customer_row_hash", CUSTOMER_ROW_HASH)
    subs.setdefault("scd2_all", scd2_ctes("TRUE"))
    subs.setdefault("scd2_affected", scd2_ctes("customer_id IN (SELECT customer_id FROM affected_customers)"))
    subs.setdefault("snapshot_ts", SNAPSHOT_TS)
    for key in sorted(subs, key=len, reverse=True):     # {name} and :name placeholders
        text = text.replace("{" + key + "}", subs[key]).replace(":" + key, subs[key])
    return text


def scd2_ctes(customer_filter):
    """includes/scd2.js -> the SCD2 CTEs, used by the initial build and the incremental run."""
    body = (SQL / "scd2_versions.sql").read_text(encoding="utf-8")
    body = "\n".join(line for line in body.splitlines() if not line.startswith("--"))
    return body.replace("{customer_filter}", customer_filter)


CUSTOMER_ROW_HASH = """sha256(to_json(struct_pack(
  customer_id := customer_id, full_name := full_name, email := email, phone := phone, city := city,
  nationality := nationality, joined_date := joined_date, loyalty_tier := loyalty_tier,
  valid_from := valid_from, valid_to := valid_to, is_current := is_current, is_inferred := is_inferred))::VARCHAR)"""


def rows_as_dicts(con, query):
    result = con.execute(query)
    columns = [d[0] for d in result.description]
    return [dict(zip(columns, row)) for row in result.fetchall()]


def write_csv(name, rows):
    path = OUT / name
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        if rows:
            writer.writerow(rows[0].keys())
            writer.writerows([[fmt(v) for v in r.values()] for r in rows])
    return path


def fmt(value):
    if isinstance(value, Decimal):
        return format(value.normalize(), "f")
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    return value


def show(rows, columns=None):
    if not rows:
        say("  (no rows)")
        return
    columns = columns or list(rows[0].keys())
    widths = [max(len(c), *(len(str(fmt(r[c]))) for r in rows)) for c in columns]
    say("  " + "  ".join(c.ljust(w) for c, w in zip(columns, widths)))
    for r in rows:
        say("  " + "  ".join(str(fmt(r[c])).ljust(w) for c, w in zip(columns, widths)))


# ---------------------------------------------------------------------------------------------
# 1. raw load: port of scripts/load_raw.py
# ---------------------------------------------------------------------------------------------
def source_of(file_name):
    if file_name == "raw_bookings.csv" or file_name.startswith("delta_bookings_"):
        return "bookings"
    if file_name == "raw_customers.csv" or file_name.startswith("delta_customers_"):
        return "customers"
    if file_name == "raw_pos_transactions.csv":
        return "pos_transactions"
    if file_name == "raw_marketing_performance.csv":
        return "marketing_performance"
    sys.exit(f"STOP  unknown file: {file_name}")


def load_file(con, path):
    """Same rules as load_raw.py: text columns, lineage, MD5 manifest (skip resend, stop on conflict)."""
    name, source = path.name, source_of(path.name)
    md5 = hashlib.md5(path.read_bytes()).hexdigest()
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows = list(reader)

    seen = [r[0] for r in con.execute("SELECT file_md5 FROM heyrcg_raw.file_manifest WHERE file_name = ?", [name]).fetchall()]
    if md5 in seen:
        return f"SKIP  {name}: already loaded (same MD5)"
    if seen:
        sys.exit(f"STOP  {name}: loaded before with a DIFFERENT MD5 ({seen[0]}). Investigate before reloading.")

    if source in ("bookings", "customers") and header[-1] != "updated_at":
        header = header + ["updated_at"]
    columns = ", ".join(f'"{c}" VARCHAR' for c in header)
    con.execute(f"CREATE TABLE IF NOT EXISTS heyrcg_raw.{source} "
                f"(_source_file VARCHAR, _source_row BIGINT, _loaded_at TIMESTAMP, {columns})")
    con.execute(f"DELETE FROM heyrcg_raw.{source} WHERE _source_file = ?", [name])

    loaded_at = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    # Same as load_raw.py: prepend the lineage columns and leave every value untouched. A missing
    # trailing field (the initial files have no updated_at) is padded, and DuckDB reads an empty
    # field as NULL, exactly as BigQuery's CSV load does.
    width = len(header)
    staged = OUT / f"_staged_{name}"
    with open(staged, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["_source_file", "_source_row", "_loaded_at"] + header)
        for line_number, row in enumerate(rows, start=2):        # line 1 is the header
            writer.writerow([name, line_number, loaded_at] + row + [""] * (width - len(row)))
    types = {"_source_file": "VARCHAR", "_source_row": "BIGINT", "_loaded_at": "TIMESTAMP"}
    types.update({c: "VARCHAR" for c in header})
    quoted = ", ".join(f'"{c}"' for c in types)
    con.execute(f"""INSERT INTO heyrcg_raw.{source} ({quoted})
        SELECT {quoted} FROM read_csv(?, header = true, auto_detect = false, delim = ',', quote = '"',
                                      escape = '"', columns = {types!r})""", [str(staged)])
    staged.unlink()

    loaded = con.execute(f"SELECT COUNT(*) FROM heyrcg_raw.{source} WHERE _source_file = ?", [name]).fetchone()[0]
    if loaded != len(rows):
        sys.exit(f"STOP  {name}: file has {len(rows)} rows, DuckDB has {loaded}")
    con.execute("INSERT INTO heyrcg_raw.file_manifest VALUES (?, ?, ?, ?, ?, NULL)",
                [name, source, md5, len(rows), loaded_at])
    return f"OK    {name} -> heyrcg_raw.{source} ({len(rows)} rows)"


def load_files(con, names):
    lines = [load_file(con, ROOT / "data" / n) for n in names]
    for line in lines:
        say("  " + line)
    return lines


# ---------------------------------------------------------------------------------------------
# 2-5. builds, incremental run, assertions, fingerprints
# ---------------------------------------------------------------------------------------------
def initial_build(con):
    for name in ["00_macros.sql", "10_reference.sql", "20_staging.sql", "30_audit.sql", "40_mart.sql", "50_reports.sql"]:
        con.execute(sql_text(name))


def incremental_run(con, backfill_from=None):
    """Port of incremental_load.sqlx: everything in ONE transaction, rolled back on any error."""
    stored = dict(con.execute("SELECT source_name, watermark_ts FROM heyrcg_audit.etl_watermark").fetchall())

    def ts(value):
        return f"TIMESTAMP '{value:%Y-%m-%d %H:%M:%S}'"

    wm = {s: (f"TIMESTAMP '{backfill_from}'" if backfill_from else ts(v)) for s, v in stored.items()}
    statements = sql_text(
        "60_incremental.sql",
        wm_customers=wm["customers"], wm_bookings=wm["bookings"],
        stored_wm_customers=ts(stored["customers"]), stored_wm_bookings=ts(stored["bookings"]),
        is_backfill="TRUE" if backfill_from else "FALSE",
    )
    con.execute("BEGIN TRANSACTION")
    try:
        con.execute(statements)
        con.execute("COMMIT")
    except Exception as error:
        con.execute("ROLLBACK")
        sys.exit(f"incremental_load rolled back: {error}")


def run_assertions(con, tag):
    text = sql_text("70_assertions.sql")
    blocks = re.split(r"^-- name: ", text, flags=re.M)[1:]
    for block in blocks:
        name, rest = block.split("\n", 1)
        tags = re.search(r"^-- tags: (.*)$", rest, flags=re.M).group(1).split()
        if tag not in tags:
            continue
        failures = rows_as_dicts(con, rest.strip().rstrip(";"))
        if failures:
            problems.append(f"assertion {name} failed after {tag} ({len(failures)} rows)")
            say(f"  FAIL  {name}: {len(failures)} rows")
            show(failures[:20])
        else:
            say(f"  PASS  {name}")


def fingerprint(con, label):
    rows = []
    for table in FINGERPRINT_TABLES:
        schema, name = table.split(".")
        columns = [r[0] for r in con.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_schema = ? AND table_name = ? "
            "ORDER BY ordinal_position", [schema, name]).fetchall()]
        content = ", ".join(f'"{c}" := "{c}"' for c in columns if c not in AUDIT_COLUMNS)
        n, fp_full, fp_content = con.execute(f"""
            SELECT COUNT(*),
                   COALESCE(bit_xor(hash(to_json(t)::VARCHAR)), 0),
                   COALESCE(bit_xor(hash(to_json(struct_pack({content}))::VARCHAR)), 0)
            FROM {table} AS t""").fetchone()
        rows.append({"table_name": table, "row_count": n, "fp_full": fp_full, "fp_content": fp_content})
    rows.sort(key=lambda r: r["table_name"])
    write_csv(f"fingerprint_{label}.csv", rows)
    return rows


REVENUE_SQL = """
SELECT year_month, hotel_name, room_revenue_idr, fnb_revenue_idr, total_revenue_idr
FROM heyrcg_mart.rpt_monthly_revenue_by_hotel WHERE year_month = '2024-03' ORDER BY hotel_name"""


# ---------------------------------------------------------------------------------------------
# 7. compare with the BigQuery run in evidence/
# ---------------------------------------------------------------------------------------------
def same(a, b):
    """Equal as numbers when both are numbers (BigQuery CSV may print 1.0 for 1), else as text
    (BigQuery prints DATETIME as 2024-03-28T00:00:00, DuckDB as 2024-03-28 00:00:00)."""
    try:
        return Decimal(str(a)) == Decimal(str(b))
    except (InvalidOperation, ValueError):
        return str(a).replace("T", " ") == str(b).replace("T", " ")


def read_evidence(name):
    path = EVIDENCE / name
    if not path.exists():
        return None
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def compare(title, evidence_name, local_rows, key_columns, value_columns, expected=None):
    """Compare local rows with the evidence file on the given columns; print one line per row."""
    if expected is None:
        expected = read_evidence(evidence_name)
    if expected is None:
        say(f"  ----  {title}: evidence/{evidence_name} not found, skipped")
        skipped.append(title)
        return
    value_columns = [c for c in value_columns if c in expected[0]]   # compare what evidence has
    local = {tuple(str(fmt(r[k])) for k in key_columns): r for r in local_rows}
    remote = {tuple(r[k] for k in key_columns): r for r in expected}
    bad = 0
    for key in sorted(set(local) | set(remote)):
        a, b = local.get(key), remote.get(key)
        if a is None or b is None:
            bad += 1
            say(f"  DIFF  {title} {key}: {'missing locally' if a is None else 'not in BigQuery evidence'}")
            continue
        for column in value_columns:
            if not same(fmt(a[column]), b[column]):
                bad += 1
                say(f"  DIFF  {title} {key} {column}: local {fmt(a[column])} vs BigQuery {b[column]}")
    if bad:
        problems.append(f"{title}: {bad} differences with evidence/{evidence_name}")
    else:
        say(f"  MATCH {title} ({len(local)} rows, columns: {', '.join(value_columns)})")


# ---------------------------------------------------------------------------------------------
def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for leftover in (DB_FILE, Path(str(DB_FILE) + ".wal")):
        leftover.unlink(missing_ok=True)
    con = duckdb.connect(str(DB_FILE))
    con.execute("SET TimeZone = 'UTC'")      # pipeline timestamps in UTC, as in BigQuery
    for schema in ("heyrcg_raw", "heyrcg_stg", "heyrcg_mart", "heyrcg_audit"):
        con.execute(f"CREATE SCHEMA {schema}")
    con.execute("""CREATE TABLE heyrcg_raw.file_manifest (
        file_name VARCHAR NOT NULL, source_name VARCHAR NOT NULL, file_md5 VARCHAR NOT NULL,
        row_count BIGINT NOT NULL, loaded_at TIMESTAMP NOT NULL, processed_at TIMESTAMPTZ)""")

    say(f"DuckDB {duckdb.__version__}, database {DB_FILE.relative_to(ROOT)}")
    say("\n== 1. Load the initial files")
    load_files(con, INITIAL_FILES)

    say("\n== 2. Initial build")
    initial_build(con)
    run_assertions(con, "initial")
    revenue_before = rows_as_dicts(con, REVENUE_SQL)
    write_csv("march_revenue_before_increment.csv", revenue_before)

    say("\n== 3. Load the delta files")
    load_files(con, DELTA_FILES)
    fp_before = fingerprint(con, "before_increment")

    say("\n== 4. Incremental run 1")
    incremental_run(con)
    run_assertions(con, "incremental")
    fp_run1 = fingerprint(con, "after_run1")
    revenue_after = rows_as_dicts(con, REVENUE_SQL)
    write_csv("march_revenue_after_increment.csv", revenue_after)

    say("\n== 5. Incremental run 2 (must change nothing)")
    incremental_run(con)
    run_assertions(con, "incremental")
    fp_run2 = fingerprint(con, "after_run2")

    say("\n== 6. Resend the same delta files (must be skipped)")
    resend = load_files(con, DELTA_FILES)
    (OUT / "resend.txt").write_text("\n".join(resend) + "\n")
    if not all(line.startswith("SKIP") for line in resend):
        problems.append("resend: a delta file was loaded twice")

    run_log = rows_as_dicts(con, """
        SELECT * REPLACE (CAST(run_ts AS TIMESTAMP) AS run_ts, CAST(created_at AS TIMESTAMP) AS created_at,
                          CAST(updated_at AS TIMESTAMP) AS updated_at)
        FROM heyrcg_audit.etl_run_log ORDER BY run_ts, source_name""")
    write_csv("run_log.csv", run_log)
    quarantine = rows_as_dicts(con, """
        SELECT source_name, action, reason, COUNT(*) AS n FROM heyrcg_stg.stg_quarantine
        GROUP BY 1, 2, 3 ORDER BY 1, 2, 3""")
    write_csv("quarantine_summary.csv", quarantine)

    # ---- results --------------------------------------------------------------------------
    say("\n== Results")
    say("\nRow counts (before increment -> after run 1 -> after run 2):")
    for a, b, c in zip(fp_before, fp_run1, fp_run2):
        say(f"  {a['table_name']:<36} {a['row_count']:>6} -> {b['row_count']:>6} -> {c['row_count']:>6}")

    say("\nMarch 2024 revenue by hotel, IDR (room revenue before -> after the delta):")
    after = {r["hotel_name"]: r for r in revenue_after}
    for r in revenue_before:
        new = after[r["hotel_name"]]["room_revenue_idr"]
        say(f"  {r['hotel_name']:<22} {r['room_revenue_idr']:>16,.0f} -> {new:>16,.0f}  ({new - r['room_revenue_idr']:+,.0f})")

    say("\nRun log:")
    show(run_log, ["source_name", "watermark_before", "watermark_after", "rows_newer_than_wm", "rows_quarantined",
                   "rows_in_batch", "rows_inserted", "rows_updated", "rows_deleted"])

    say("\nIdempotency (run 1 vs run 2, every column including created_at/updated_at):")
    if fp_run1 == fp_run2:
        verdict = "IDEMPOTENT: after_run2 is identical to after_run1 for every mart table"
    else:
        verdict = "DIFFERENT: run 2 changed something"
        problems.append(verdict)
        for a, b in zip(fp_run1, fp_run2):
            if a != b:
                say(f"  run1: {a}\n  run2: {b}")
    say("  " + verdict)
    (OUT / "idempotency_result.txt").write_text(verdict + "\n")

    say("\n== Compare with the BigQuery run (evidence/)")
    say("  (keys and hashes come from different hash functions in DuckDB and BigQuery, so fp_* values")
    say("   are not compared across engines; run 1 = run 2 is checked above instead)")
    compare("row counts before increment", "fingerprint_before_increment.csv", fp_before, ["table_name"], ["row_count"])
    compare("row counts after run 1", "fingerprint_after_run1.csv", fp_run1, ["table_name"], ["row_count"])
    compare("row counts after run 2", "fingerprint_after_run2.csv", fp_run2, ["table_name"], ["row_count"])
    revenue_columns = ["room_revenue_idr", "fnb_revenue_idr", "total_revenue_idr"]
    compare("March revenue before", "march_revenue_before_increment.csv", revenue_before, ["hotel_name"], revenue_columns)
    compare("March revenue after", "march_revenue_after_increment.csv", revenue_after, ["hotel_name"], revenue_columns)
    compare("quarantine summary", "quarantine_summary.csv", quarantine, ["source_name", "action", "reason"], ["n"])
    # run log: compare run by run (run_ts differs between engines, so number the runs 1, 2)
    local_log = [dict(r, run=str(i // 2 + 1)) for i, r in enumerate(run_log)]
    evidence_log = read_evidence("run_log.csv")
    if evidence_log is not None:
        evidence_log.sort(key=lambda r: (r["run_ts"], r["source_name"]))
        evidence_log = [dict(r, run=str(i // 2 + 1)) for i, r in enumerate(evidence_log)]
    compare("run log", "run_log.csv", local_log, ["run", "source_name"],
            ["watermark_before", "watermark_after", "rows_newer_than_wm", "rows_quarantined",
             "rows_in_batch", "rows_inserted", "rows_updated", "rows_deleted"], expected=evidence_log)

    for name in ("resend.txt", "idempotency_result.txt"):
        theirs = EVIDENCE / name
        if not theirs.exists():
            say(f"  ----  {name}: evidence/{name} not found, skipped")
            skipped.append(name)
        elif theirs.read_text(encoding="utf-8").strip() == (OUT / name).read_text(encoding="utf-8").strip():
            say(f"  MATCH {name} (same text)")
        else:
            problems.append(f"{name} differs from evidence/{name}")
            say(f"  DIFF  {name}")

    say("\n== Judgement calls: what the other option would give (README, section Assumptions)")
    alternatives = rows_as_dicts(con, sql_text("80_alternatives.sql"))
    write_csv("assumption_alternatives.csv", alternatives)
    show([r for r in alternatives if r["hotel_name"] == "All hotels"],
         ["decision", "metric", "alternative_option", "chosen_value", "alternative_value", "difference_pct"])
    say("  (per hotel: local/output/assumption_alternatives.csv)")

    con.close()
    say(f"\nOutputs written to {OUT.relative_to(ROOT)}/")
    if problems:
        say("\nFAILED:")
        for p in problems:
            say(f"  - {p}")
        sys.exit(1)
    if skipped:
        say(f"\nALL GOOD: assertions passed and run 2 changed nothing ({len(skipped)} comparisons with "
            "evidence/ skipped because the files are missing).")
    else:
        say("\nALL GOOD: assertions passed, run 2 changed nothing, numbers match the BigQuery evidence.")


if __name__ == "__main__":
    main()
