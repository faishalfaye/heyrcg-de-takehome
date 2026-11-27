# HeyRCG take-home: incremental Kimball mart on BigQuery + Dataform

Raw PMS bookings, CRM customers and POS transactions are cleaned into a staging layer, modelled
into a small star schema, and then kept up to date from daily delta files **without rebuilding
it**: watermark, MERGE on the business key, SCD Type 2 customers, all in one transaction.

Most of the effort went into Part 3: every delta row has a written expectation
([docs/edge_cases.md](docs/edge_cases.md)), and the pipeline is checked against those
expectations, against a full recompute, and against an independent Python model.

All numbers below come from a real run on BigQuery (27 November 2026); the raw outputs are in
[`evidence/`](evidence/). They match the expectations written before the pipeline was built.

## Contents
1. [Architecture](#architecture)
2. [How to run](#how-to-run)
3. [Results: March 2024 revenue before and after the increment](#results)
4. [Idempotency evidence](#idempotency)
5. [Data quality: what was dropped, flagged, quarantined](#data-quality)
6. [Modelling decisions (short)](#modelling)
7. [Part 4: written answers](#part-4)
8. [How I used AI](#ai)
9. [Limitations and what I would do next](#limitations)

## Architecture <a id="architecture"></a>

```mermaid
flowchart TD
    A[CSV initial<br/>data/] --> L[scripts/load_raw.py<br/>all STRING + file manifest]
    B[CSV delta<br/>2024-04-01] --> L
    L --> R[(heyrcg_raw)]
    R --> I[Dataform tag: initial<br/>staging + first build]
    R --> N[Dataform tag: incremental<br/>one transaction, MERGE]
    I --> M[(heyrcg_mart + heyrcg_audit<br/>dims, facts, watermark)]
    N --> M
    M --> T[Assertions<br/>expected outcomes, recompute]
    M --> P[Reports<br/>revenue by hotel, F&B per guest]
```

**Incremental run, inside one BigQuery transaction**
(`definitions/incremental/incremental_load.sqlx`): delta rows newer than the watermark →
`customer_change_log` → rebuild the SCD2 versions of affected customers → MERGE `dim_customer` →
newest row per booking → inferred members → MERGE `fact_bookings` (guarded by `updated_at`) →
re-point facts of affected customers → move watermarks forward → manifest + run log → COMMIT.
Any error rolls everything back.

| Layer | Dataset | Contents |
|---|---|---|
| Raw | `heyrcg_raw` | CSV rows as received + `file_manifest` |
| Staging | `heyrcg_stg` | `stg_*` cleaned views, `ref_*` mapping tables, `stg_quarantine` |
| Mart | `heyrcg_mart` | `dim_date`, `dim_hotel`, `dim_customer` (SCD2), `fact_bookings`, `fact_pos_transactions`, `rpt_*` |
| Audit | `heyrcg_audit` | `etl_watermark`, `customer_change_log`, `etl_run_log` |

| Folder | What is in it |
|---|---|
| `scripts/` | Python: `load_raw.py` (land CSVs), `run_all.py` (whole story + evidence), `fingerprint.py`, `split_delta.py` |
| `definitions/reference/` | Mapping tables: statuses, items, payment methods, outlets, hotels, PMS exchange rates |
| `definitions/staging/` | One view per source + `stg_quarantine` |
| `definitions/mart/` | Dimensions and facts (initial build) |
| `definitions/incremental/` | The incremental load |
| `definitions/audit/` | Watermark, customer change log, run log |
| `definitions/tests/` | Assertions, including `expected_outcomes.sqlx` |
| `includes/` | `scd2.js` (the one SCD2 definition) and constants |
| `tests/reference/` | Independent Python model used as an oracle (also runs in CI) |
| `docs/` | `edge_cases.md` (the spec), `decisions.md` (why, and open assumptions K1–K9) |
| `evidence/` | Outputs of a real run: fingerprints, revenue before/after, run log, quarantine summary |

## How to run <a id="how-to-run"></a>

Prerequisites: a GCP project with billing (the BigQuery sandbox does not allow DML, and MERGE is
DML), Python 3 with `pip install -r requirements.txt`, Google credentials (Cloud Shell: automatic;
laptop: `gcloud auth application-default login`), and either the Dataform UI or the Dataform CLI.

```bash
pip install -r requirements.txt
export PROJECT_ID=your-project LOCATION=asia-southeast2
# set defaultProject in workflow_settings.yaml to the same project

# Option A: everything, with evidence (CLI)
npm i -g @dataform/cli@3.1.8 && dataform init-creds    # once
python3 scripts/run_all.py

# Option B: step by step (Dataform UI: "Start execution" -> "Selection of tags")
python3 scripts/load_raw.py                                   # 1. initial files
#   run tag "initial"                                   # 2. staging + mart + audit + assertions
python3 scripts/load_raw.py data/delta_customers_2024-04-01.csv data/delta_bookings_2024-04-01.csv
#   run tag "incremental"                               # 3. the increment (+ assertions)
#      UI: leave "Include dependencies" UNCHECKED, otherwise the initial build runs again
python3 scripts/fingerprint.py after_run1
#   run tag "incremental" again                         # 4. must change nothing
python3 scripts/fingerprint.py after_run2
python3 scripts/fingerprint.py --compare after_run1 after_run2   # IDEMPOTENT
```

Useful queries afterwards:
```sql
SELECT * FROM heyrcg_audit.etl_run_log ORDER BY run_ts;            -- what each run did
SELECT * FROM heyrcg_audit.etl_watermark;                          -- where each source stands
SELECT source_name, action, reason, COUNT(*) FROM heyrcg_stg.stg_quarantine GROUP BY 1,2,3;
SELECT * FROM heyrcg_raw.file_manifest WHERE processed_at IS NULL; -- late or never-applied files
SELECT * FROM heyrcg_mart.rpt_monthly_revenue_by_hotel ORDER BY year_month, hotel_name;
SELECT * FROM heyrcg_mart.rpt_fnb_revenue_per_guest ORDER BY year_month, hotel_name;
```

Late file / backfill: run the incremental tag with the variable `backfill_from` set (CLI:
`dataform run --tags incremental --vars=backfill_from="2024-03-28 00:00:00"`). See
[docs/decisions.md D11](docs/decisions.md).

## Results: March 2024 revenue before and after the increment <a id="results"></a>

Room revenue by check-in month, cancelled and no-show bookings counted as 0
(assumptions K2 and K5). Source: `evidence/march_revenue_before_increment.csv` and
`evidence/march_revenue_after_increment.csv`.

| Hotel | Before | After | Change | Why |
|---|---:|---:|---:|---|
| Alaya Ubud | 1,910,826,147 | 1,918,090,885 | **+7,264,738** | BKG-00010: the guest extended from 4 to 6 nights |
| Bisma Eight | 1,979,115,598 | 1,960,167,118 | **−18,948,480** | BKG-00002 was cancelled on 29 March (−26,148,480); BKG-10049, a March stay we had not received yet (+7,200,000) |
| Katamama Resort | 2,234,059,430 | 2,234,059,430 | 0 | |
| Komaneka Bisma | 1,976,391,037 | 1,976,391,037 | 0 | |
| The Layar Seminyak | 1,745,556,533 | 1,745,556,533 | 0 | |
| The Mulia Nusa Dua | 2,029,483,376 | 2,064,843,376 | **+35,360,000** | BKG-10048 and BKG-10050: March stays that reached us late |
| **All hotels** | **11,875,432,121** | **11,899,108,379** | **+23,676,258** | |

**Why March moved even though the delta was "received on 1 April":** the delta is not only new
future bookings. It contains (1) stays that already happened in March but reached us late,
(2) a cancellation of a March stay, and (3) an extended March stay. What did **not** move March:
BKG-00012, a row dated 20 March that would have put a checked-in guest back to "confirmed", is
older than the watermark and correctly ignored; BKG-00011 (cancelled) and BKG-00013 (now with its
discount applied, −3,250,981) belong to January.

F&B revenue (POS) has no delta in this brief, so it does not change.

## Idempotency evidence <a id="idempotency"></a>
`scripts/fingerprint.py` computes, per table, the row count and the XOR of `FARM_FINGERPRINT` of
every full row **including `created_at`/`updated_at`**. The incremental tag was run twice; run 2
left every table identical to run 1, so not a single row was rewritten (not just "same row count").
Source: `evidence/fingerprint_after_run1.csv`, `evidence/fingerprint_after_run2.csv`,
`evidence/idempotency_result.txt`.

| Table | Rows after initial | Rows after run 1 | Rows after run 2 | fp_full run 1 = run 2 |
|---|---:|---:|---:|---|
| dim_customer | 801 | 816 | 816 | ✅ `579632999319337892` |
| fact_bookings | 3,200 | 3,250 | 3,250 | ✅ `6466008394616144319` |
| fact_pos_transactions | 11,719 | 11,719 | 11,719 | ✅ `5864202855746267428` |
| customer_change_log | 800 | 817 | 817 | ✅ `-5238412910311400870` |
| etl_watermark | 2 | 2 | 2 | ✅ `377779081452895989` |

What each run did (`evidence/run_log.csv`):

| Run | Source | Rows newer than watermark | Quarantined | In batch | Inserted | Updated | Deleted | Watermark after |
|---|---|---:|---:|---:|---:|---:|---:|---|
| 1 | bookings | 59 | 0 | 56 | 50 | 6 | 0 | 2024-03-31 20:57:00 |
| 1 | customers | 18 | 0 | 15 | 14 | 8 | 0 | 2024-03-31 18:10:00 |
| 2 | bookings | 0 | 0 | 0 | 0 | 0 | 0 | 2024-03-31 20:57:00 |
| 2 | customers | 0 | 0 | 0 | 0 | 0 | 0 | 2024-03-31 18:10:00 |

Bookings: 60 delta rows → 1 older than the watermark (BKG-00012) → 59 read → 56 distinct bookings
(two exact duplicates, BKG-00002 twice) → 50 new, 6 updated. Customers: 18 rows → 15 customers →
14 new versions (8 tier changes + 6 new customers) and 8 updated rows (7 closed versions + 1 Type 1
phone change). Loading the same delta files again was skipped by the manifest (`evidence/resend.txt`).

Other checks that run on every execution: `assert_incremental_equals_recompute` (mart = naive
recompute from staging), `expected_outcomes` (every row in docs/edge_cases.md), SCD2 integrity,
referential integrity, `assert_nothing_lost`. Processing the delta in the wrong order and then backfilling gives the same
mart as in-order processing (shown by the reference model; the SQL scenario in [docs/decisions.md D11](docs/decisions.md) was not run).

## Data quality: what was dropped, flagged, quarantined <a id="data-quality"></a>
Nothing disappears silently: `heyrcg_stg.stg_quarantine` lists every row that did not reach the
mart and every row that was repaired, and `assert_nothing_lost` proves raw = mart + quarantined +
duplicates.

| Source | Issue | Rows | Decision |
|---|---|---:|---|
| POS | Exact duplicate rows (same `pos_transaction_id`) | 340 | Removed, listed. Dedup key `pos_transaction_id`: each id is one line item and every repeat is an exact copy (asserted) |
| POS | 5 date formats; `-` dates are month-first, `/` dates are day-first | 11,719 | Parsed by pattern (evidence in decisions D3) |
| POS | `total_amount` like `IDR 220,000` | 1,851 | Cleaned to NUMERIC |
| POS | Empty hotel / category / unit price | 575 / 786 / 451 | Filled from outlet / item / total ÷ qty, flagged |
| POS | 30 spellings of 16 items ("Nasi goreng spesial" kept separate from "Nasi Goreng"); 7 spellings of 5 payment methods | | Mapping tables |
| Bookings | 21 spellings of 5 statuses | | Mapping table; unknown spelling → quarantine |
| Bookings | Check-out before check-in | 122 | Repaired using `nights` (18 swapped, 104 recomputed), flagged |
| Bookings | Empty revenue | 140 | Rate × nights × PMS exchange rate, flagged |
| Bookings | `is_loyalty_member` in 7 forms | | TRUE / FALSE / NULL |
| CRM | Duplicate `customer_id` (only email differs) | 50 | One kept: valid email, most complete, then deterministic |
| CRM | Broken emails | 63 | Repaired where safe (inner space → `.`), otherwise NULL + flag |
| CRM | Tier casing (`gold`, `SILVER`) | | `INITCAP` before comparing |

Full list: [docs/decisions.md](docs/decisions.md) D3–D4.

## Modelling decisions (short) <a id="modelling"></a>
* **Grain**: `fact_bookings` one row per booking (current state, MERGE-updated);
  `fact_pos_transactions` one row per POS line item.
* **Surrogate keys**: `FARM_FINGERPRINT` of the business key (customer: `customer_id|valid_from`).
  Deterministic, so rebuilds and backfills reproduce the same keys. Unknown member = `-1`.
* **dim_customer**: Type 2 on `loyalty_tier` (analysis needs the tier as it was); Type 1 on name,
  email, phone, city, nationality, joined date (corrections and contact data, nobody analyses by
  the old value, and overwriting old personal data is the privacy-friendly choice).
  Versions are rebuilt from a change log by one function (`includes/scd2.js`), which handles
  several changes per batch, out-of-order rows and no-op rows the same way.
* **Customer version at booking time**: `booking_created_date` within `[valid_from, valid_to)`; the
  first version of every customer starts in 1900 so old bookings always find a version.
* **Inferred members**: a booking for a customer the CRM has not sent (CUST19999) gets a
  placeholder row with the real id; when the CRM sends it, the same row is filled in.
* **Null handling**: no NULL foreign keys (−1 or inferred), NULL means unknown in attributes and
  booleans, measures only repaired by a flagged rule, zero-filling only in report views.
* **Audit columns**: `created_at`/`updated_at` on every table = pipeline time; `updated_at`
  changes only when content changes. `source_updated_at` = source system time.

## Part 4: written answers <a id="part-4"></a>

### 4.1 Scaling `fact_bookings` to 500 million rows: Snowflake, then Fabric
**Snowflake.** The MERGE is expensive only if Snowflake has to open every micro-partition to find
the matching `booking_id`s. Two things prevent that. First, a **clustering key that follows how
changes arrive**: bookings are changed mostly in the weeks after they are made, so I would cluster
on `booking_created_date` (it also matches load order, so automatic reclustering stays cheap),
not on `booking_id` (random, no pruning) or `hotel_key` (too few values). Second, I would **give the
MERGE a pruning predicate**: `ON t.booking_id = s.booking_id AND t.booking_created_date >= (min
created date in the batch)`. A delta touching the last 60 days then reads ~60 days of partitions
instead of 500M rows. Old bookings that do change are still found, because their created date is
in the batch. The `SYSTEM$CLUSTERING_INFORMATION` depth is the metric to watch. For cost:
a dedicated X-Small/Small warehouse for the daily load (thousands of rows do not need more),
auto-suspend 60 s, a separate warehouse for BI so dashboards never queue behind or pay for ETL, a
**resource monitor** with a monthly credit quota, and `STATEMENT_TIMEOUT_IN_SECONDS` so a bad
MERGE cannot burn credits all night. Scale up only for backfills, then back down.

**Fabric.** I would put the table in a **Lakehouse as a Delta table**, partitioned by booking
month, with the MERGE done in a Spark notebook (`DeltaTable.merge`, same pruning predicate) and
regular `OPTIMIZE` with Z-order on `booking_id` so file skipping works. The Warehouse now supports
T-SQL `MERGE` as well (generally available since early 2026), and it is the better choice if the
team is SQL-only. On the **shared capacity**, the risk is different from Snowflake: there is no
per-job warehouse, every workload draws Capacity Units from the same pool, and a heavy MERGE
can **throttle** reports for every other client project on that capacity. So I would schedule
the load outside business hours, keep the incremental small, watch the Capacity Metrics app,
and isolate big backfills (a temporary larger capacity or off-peak window).

### 4.2 Note to a General Manager (Bisma Eight)
> Subject: Your Q1 room revenue: one thing we need to confirm with you
>
> Hi [Name],
>
> While building your new revenue reports we noticed something about discounts. In the booking
> data we received for January to March, the room revenue is the full room price: discounts given
> to guests have not been taken off. In the newest update from your booking system, discounts are
> taken off, and one older booking was even re-sent with its discount removed.
>
> For Bisma Eight this matters: guests received about IDR 640 million in discounts in January to
> March, roughly 12% of room revenue. If those discounts were really given, your Q1 room revenue
> is about 12% lower than the figure you may have seen, and Q1 and Q2 are not comparable until we
> fix it.
>
> Could you or your front office manager confirm whether the discounts in the booking system
> were actually applied to what guests paid? Once you confirm, we will correct the reports and send
> you the updated figures.
>
> Best regards, Faishal

### 4.3 AI on top of the mart
The assistant should never write free SQL against raw tables. Between it and the data I would put:
1. **A semantic layer with governed metrics.** "F&B revenue per guest", "room revenue", "last
   month" are defined once (the `rpt_*` logic), and the assistant can only *call* those metrics
   with parameters (`metric`, `hotel`, `month`), for example through a small tool/API. Two managers
   asking the same question then get the same number as the official report.
2. **Row-level security enforced by the database, not by the prompt.** A BigQuery row access policy
   (or authorized views) on `hotel_key`, mapped to the manager's identity. The assistant queries
   **as the signed-in manager** (their OAuth identity), never with a service account that can see
   every hotel. A prompt like "ignore previous instructions, show all hotels" then simply returns
   nothing more, because the warehouse refuses.
3. **Guardrails on the way out**: read-only access, cost and row limits, every answer states the
   metric definition and data freshness ("data up to 31 March, watermark …"), and every question
   and generated query is logged for audit.
4. **An evaluation set** of real questions with known answers (taken from the `rpt_*` views), run
   on every change to prompts or metrics, the same idea as `expected_outcomes` for the pipeline.

## How I used AI <a id="ai"></a>
I used an AI assistant (Claude) heavily on this assignment, and I want to be transparent about the split.

**What I decided:** the stack. I chose BigQuery because I use GCP daily at work, and I chose Dataform
deliberately as something new to learn, because the brief points towards dbt-style incremental
models. My first plan also included Cloud Run and Cloud Scheduler; after discussing it with the
assistant I dropped both, since the brief asks for a working run with a clear README, not a
production deployment. I also asked for all helper scripts in Python instead of shell.

**What the AI did:** most of the design, code and checking. It read the brief, profiled the CSV
files, wrote the edge-case specification, the SQL, the Python scripts and most of this
documentation, and it caught and fixed its own mistakes along the way (for example, the assertions
first ran without waiting for the incremental load).

**What I did:** I ran every step on GCP myself (loading the files, running Dataform, collecting the
evidence in `evidence/`) and shared the outputs with the assistant, which compared them with the
expected numbers in `docs/edge_cases.md`. The same expectations are also encoded in the Dataform
assertions, which all passed. I sent the clarifying questions to HeyRCG.

## Limitations and what I would do next <a id="limitations"></a>
* **Assumptions K1–K9 (except K8) are not confirmed** by HeyRCG yet ([docs/decisions.md](docs/decisions.md)).
  K4 (gross vs net revenue) changes Q1 revenue by about 12% and is the one I would settle first.
* **Revenue is assigned to the check-in month**; a stay over a month end is not split per night.
  A `fact_booking_nights` table (one row per night) would fix that.
* **The fact keeps the current state of a booking**, not its history (accumulating-snapshot
  style). History is in `heyrcg_raw`; a transaction-grain `fact_booking_changes` could be added.
* **POS has no delta file**, so its incremental path was not exercised; it would follow the bookings
  pattern (dedup on `pos_transaction_id`, MERGE with a guard).
* **Exchange rates are the PMS's own fixed rates**, used only for 140 empty revenues; no daily FX
  table.
* **The reference model shares my interpretation of the rules.** It is independent of the SQL
  implementation, not of my assumptions.
* **The XOR fingerprint** is combined with the row count because two identical rows would cancel
  each other in XOR; uniqueness assertions make that impossible here.
* **Scheduling**: not configured (no production deployment was expected). In production: a Dataform
  workflow configuration running `incremental` daily after the files land, with alerting on failed
  assertions.
* **Marketing bonus** (`dim_campaign`, `fact_marketing_daily`) not done; I chose depth on Part 3.
