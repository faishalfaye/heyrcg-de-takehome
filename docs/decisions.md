# Design decisions

Each decision says what was chosen, why, and what it costs. Open questions for the client are
marked **ASSUMPTION Kn**: they are the defaults the code uses until HeyRCG answers, and each one
is a single, easy-to-find place in the code.

## Open assumptions (waiting for HeyRCG; K8 resolved, see D3)

| Id | Question | What the code does now | Where to change it |
|---|---|---|---|
| K1 | Do reviewers need to run the pipeline themselves? | Repo + `evidence/` outputs; `scripts/run_all.sh` for anyone with a GCP project | n/a |
| K2 | Which month does room revenue belong to? | Check-in month (a stay crossing a month end is not split) | `rpt_monthly_revenue_by_hotel.sqlx` |
| K3 | "Customer version valid at booking time": which date? | Booking `created_at` | join conditions on `booking_created_date` |
| K4 | Is `TotalRevenue_IDR` gross or net of `discount_pct`? Initial rows are gross (= rate × nights × FX for all 3,060 rows with a value); new delta bookings are net | Use the PMS value as is; derive only when empty (gross, like the initial load) | `stg_bookings.sqlx` `room_revenue_idr` |
| K5 | Do cancelled / no-show bookings count as revenue? | No: `recognised_room_revenue_idr` = 0; the PMS amount is kept in `room_revenue_idr` | `constants.NON_REVENUE_STATUSES` |
| K6 | Is "no tier" → Bronze a tier change? | Yes, a new SCD2 version | `includes/scd2.js` (`IS DISTINCT FROM`) |
| K7 | Does `completed` mean checked out? | Yes | `ref_booking_status.sqlx` |
| K9 | "F&B revenue per guest": who is a guest? | A POS line with a customer_id; walk-in sales reported separately | `rpt_fnb_revenue_per_guest.sqlx` |

## D1. Land raw data untouched
CSV files are loaded with `bq load` with **every source column as STRING and autodetect off**
(`scripts/load_raw.sh`). Autodetect would silently change data: phone numbers lose their leading
zero, `03-15-2024` and `15/03/2024` are guessed with one rule, `"IDR 220,000"` becomes NULL. Each
row gets `_source_file`, `_source_row` (line number) and `_loaded_at`, so any mart row can be traced
back to a line of a file. Every file is recorded in `heyrcg_raw.file_manifest` with its MD5:
the same file twice is skipped, the same name with different content stops the load.

## D2. Layers and naming
`heyrcg_raw` (files as received) → `heyrcg_stg` (cleaned views, reference tables, quarantine)
→ `heyrcg_mart` (Kimball star + report views) and `heyrcg_audit` (watermark, change log, run log).
Everything is `snake_case`. Source names like `BookingID` / `CheckInDate` exist only in raw.
Prefixes: `stg_`, `ref_`, `dim_`, `fact_`, `rpt_`, `assert_`.

## D3. Cleaning rules (staging)
* **Dates**: bookings/CRM are already `YYYY-MM-DD`. POS has five formats, parsed by pattern.
  `NN-NN-YYYY` is **month-first** and `NN/NN/YYYY` is **day-first**: in this file the first number
  of every dash date is ≤ 3 while the second goes up to 31, and the reverse for slash dates. A single
  rule for both would put ~40% of POS lines on the wrong day without any error.
* **Amounts**: `IDR`, thousands commas and spaces removed, cast to `NUMERIC` (exact decimals, no
  float rounding on money).
* **Statuses, items, payment methods**: mapped through small reference tables (`ref_*`). An
  unmapped value goes to quarantine instead of being guessed. "Nasi goreng spesial" is kept as its
  own item, not merged into "Nasi Goreng": in Indonesia these are two different dishes. In this
  file both use the same price list, so the choice changes item-level reporting only, not revenue.
* **Booleans**: `1/true/yes` → TRUE, `0/false/no` → FALSE, empty → NULL (unknown, not FALSE).
* **Emails**: trim, lower-case, inner whitespace → `.`, then validated. The CRM itself corrects
  `customer 2@hotmail.com` to `customer.2@hotmail.com` in the delta, which is the evidence for the
  rule. Still invalid → NULL + `is_email_invalid` (63 initial rows).
* **Check-out before check-in (122 bookings)**: `nights` always matches revenue (rate × nights), so
  nights is trusted. If the gap equals nights the dates were swapped (18 rows: swap back), otherwise
  check-out = check-in + nights (104 rows). Flagged in `date_fix`.
* **Empty revenue (140 bookings)**: rate × nights × PMS exchange rate, flagged
  `is_revenue_derived`. The rates (USD 15,800 / AUD 10,200 / SGD 11,700) are not invented: they are
  exactly what the PMS used on every other row.
* **POS empty hotel (575 kept rows)**: filled from the outlet (each outlet belongs to one hotel).
  **Empty category (786)**: filled from the item (each item has one category).
  **Empty unit price (451)**: total ÷ quantity.

## D4. Drop, flag or quarantine
Nothing is deleted silently. `heyrcg_stg.stg_quarantine` lists every row that does not reach the
mart (with the reason) and every row that was repaired (with the repair):
* **Quarantine** (kept out, listed): missing key, unparseable date/amount, unknown status, hotel,
  currency, item or payment method. With this data: 0 rows, but each rule is tested by the
  assertions and would catch a new bad value tomorrow.
* **Duplicate removed** (listed): 340 POS exact copies, 50 CRM duplicate customer_ids.
* **Flagged** (in the mart, with a flag column): the repairs in D3.
`assert_nothing_lost` proves the accounting: raw rows = mart + quarantined + duplicates.

## D5. dim_customer: SCD Type 2 on loyalty_tier, Type 1 on the rest
`loyalty_tier` is Type 2 because analysis needs it **as it was** (revenue of Gold members in
March). `full_name`, `email`, `phone`, `city`, `nationality`, `joined_date` are Type 1: changes are
corrections or contact details, nobody reports "revenue by the email the guest had in February",
and overwriting old personal data is also the privacy-friendly choice. Type 1 values are written on
**all** versions of a customer.

**How the versions are built** (`includes/scd2.js`, one function used by both the initial and the
incremental load): `heyrcg_audit.customer_change_log` keeps every accepted CRM row. A customer's
versions are a pure function of that log: sort by time; a version starts at the first row and at
every tier change; the first version starts 1900-01-01; `valid_to` = next version's `valid_from`.
Consequences: several changes in one batch (CUST00006), rows out of order (CUST00010), duplicates
and rows that change nothing are all handled by the same 30 lines, and re-running gives the same
result. Alternative considered: `dbt snapshot`-style "compare latest row with current version". It
keeps only the last state per run, so CUST00006's Gold period would be lost.

## D6. Surrogate keys: FARM_FINGERPRINT of the business key
`booking_key = FARM_FINGERPRINT(booking_id)`, `customer_key = FARM_FINGERPRINT(customer_id | valid_from)`,
`hotel_key = FARM_FINGERPRINT(hotel_code)`. Deterministic: a rebuild, a backfill or a second
environment gives the same keys, so facts never point at a key that has disappeared, and the
idempotency fingerprint can compare two runs. A sequence would depend on load order. Cost: a 64-bit
hash can collide; for a million keys the chance is about 3 in 100 million, and the uniqueness
assertions would catch it. `date_key` is `YYYYMMDD`. Unknown members use `-1`.

## D7. Grain
* `fact_bookings`: one row per booking (`booking_id` unique). A changed booking is updated, not
  added as a new row: the brief asks for current state with MERGE. Booking history lives in raw.
* `fact_pos_transactions`: one row per POS line item (`pos_transaction_id` unique after removing
  exact copies).
* `dim_date`: 2023-01-01 to 2024-12-31, wider than Q1–Q2 2024 because booking dates start in
  October 2023 and stays run into May 2024.

## D8. Null handling (one rule per kind of column)
| Column kind | Rule |
|---|---|
| Foreign keys in facts | Never NULL. Unknown → `-1` member; known id missing from its dimension → inferred member |
| Descriptive attributes | NULL = unknown. No fake values ('N/A', 'Unknown') in data columns |
| Booleans | NULL = unknown, never defaulted to FALSE |
| Measures | Repaired only by a documented rule and flagged (`is_revenue_derived`, `is_unit_price_derived`); otherwise the row is quarantined |
| Reports | `IFNULL(…, 0)` only at the presentation layer (`rpt_*`), never in facts |

## D9. Watermark
`heyrcg_audit.etl_watermark`, one row per source, `DATETIME` (source timestamps have no time
zone). A run reads delta rows with `updated_at > watermark` (strictly greater: the 03-28 00:00:00
extraction itself is already in the initial load). After the run the watermark becomes the
newest `updated_at` read, including quarantined rows (they were seen; re-reading them would
not fix them). It only moves forward, and it is updated **in the same transaction** as the data,
so a failed run never leaves a watermark that claims work was done.

## D10. MERGE with a guard
Rows are deduplicated to the newest per booking, then labelled before the MERGE:
`INSERT` (new id), `UPDATE` (newer and different), `TOUCH` (newer, same content: only
`source_updated_at` moves), `IGNORED_OLDER` (not newer than the fact). The guard
`source.updated_at > target.source_updated_at` means an older row can never overwrite a newer one,
whatever order files arrive in. `updated_at` (audit) changes only on a real change.

## D11. Late files, out-of-order files, backfill
* Normal run: a file whose rows are all older than the watermark is not applied and stays
  `processed_at IS NULL` in the manifest, which makes it visible
  (`SELECT * FROM heyrcg_raw.file_manifest WHERE processed_at IS NULL`).
  `assert_incremental_equals_recompute` also fails, because the mart no longer matches a recompute.
* Fix: run the incremental load with the Dataform variable `backfill_from` (e.g.
  `2024-03-28 00:00:00`). Customers are rebuilt from the change log (order-independent) and
  bookings go through the guard, so the result equals in-order processing. Proven by the reference
  model ("Out-of-order + backfill == in-order: True") and by this SQL scenario, which builds a
  second copy of everything with the suffix `_ooo`:
  ```bash
  ./scripts/split_delta.sh                                   # delta -> a 03-29 file and a 03-31 file
  export RAW_DATASET=heyrcg_raw_ooo DATASET_SUFFIX=_ooo
  ./scripts/load_raw.sh
  dataform run --tags initial     --schema-suffix=ooo --vars=raw_dataset=heyrcg_raw_ooo
  ./scripts/load_raw.sh data/out_of_order/delta_customers_2024-03-31.csv data/out_of_order/delta_bookings_2024-03-31.csv
  dataform run --tags incremental --schema-suffix=ooo --vars=raw_dataset=heyrcg_raw_ooo     # tomorrow's file first
  ./scripts/load_raw.sh data/out_of_order/delta_customers_2024-03-29.csv data/out_of_order/delta_bookings_2024-03-29.csv
  dataform run --tags incremental --schema-suffix=ooo --vars=raw_dataset=heyrcg_raw_ooo,backfill_from="2024-03-28 00:00:00"
  ./scripts/fingerprint.sh out_of_order ooo
  # compare the fp_content column with evidence/fingerprint_after_run1.csv: must be equal
  ```
  Without the backfill step the 03-29 rows stay unapplied (and `assert_incremental_equals_recompute`
  fails), which is the honest answer to "what if tomorrow's file arrives before today's".
* A bug in March staging logic: fix the SQL, re-run `--tags initial` (rebuilds everything from raw,
  resets the watermark), then `--tags incremental` (replays every delta in raw). Raw is never
  modified, so a rebuild is always possible.

## D12. Idempotency
Three layers: (1) loading: same file is skipped by the manifest; (2) the watermark makes a second
run read nothing; (3) even if rows are re-read (backfill), change detection by hash means nothing is
rewritten. Proof: `scripts/fingerprint.sh` hashes every row of every mart table, audit columns
included, after run 1 and run 2; the files must be identical (`evidence/`).

## D13. Audit columns
`created_at` = when the pipeline first wrote the row, `updated_at` = when the pipeline last
changed its content (pipeline time, `TIMESTAMP`, UTC). Not to be confused with
`source_updated_at` = when the source system changed the record (`DATETIME`, source clock).
Inside the transaction all rows of one run share the same `run_ts`.
