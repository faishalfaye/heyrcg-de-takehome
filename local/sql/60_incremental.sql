-- Port of definitions/incremental/incremental_load.sqlx.
-- run_local.py runs every statement below inside ONE transaction (BEGIN ... COMMIT, ROLLBACK on
-- any error) and replaces the placeholders :wm_customers, :wm_bookings, :stored_wm_customers,
-- :stored_wm_bookings, :is_backfill. COUNT(*) FILTER is used instead of COUNT_IF because
-- DuckDB's COUNT_IF returns NULL on an empty table, where BigQuery's COUNTIF returns 0. current_timestamp is the transaction start time in DuckDB,
-- so every row written by one run gets the same timestamp (like run_ts in BigQuery).

-- 1. CUSTOMERS ------------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE cust_candidates AS
SELECT * FROM heyrcg_stg.stg_customers
WHERE NOT is_snapshot_row AND row_ts > :wm_customers;

INSERT INTO heyrcg_audit.customer_change_log
  (customer_id, full_name, email, phone, city, nationality, joined_date, loyalty_tier,
   row_ts, row_hash, source_file, source_row, created_at, updated_at)
SELECT customer_id, full_name, email, phone, city, nationality, joined_date, loyalty_tier,
       row_ts, row_hash, source_file, source_row, current_timestamp, current_timestamp
FROM cust_candidates AS c
WHERE quarantine_reason IS NULL
  AND NOT EXISTS (SELECT 1 FROM heyrcg_audit.customer_change_log AS l
                  WHERE l.customer_id = c.customer_id AND l.row_ts = c.row_ts AND l.row_hash = c.row_hash)
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id, row_ts, row_hash ORDER BY source_file, source_row) = 1;

CREATE OR REPLACE TEMP TABLE affected_customers AS
SELECT DISTINCT customer_id FROM cust_candidates WHERE quarantine_reason IS NULL;

CREATE OR REPLACE TEMP TABLE new_versions AS
WITH
{scd2_affected}
SELECT *, {customer_row_hash} AS row_hash FROM customer_versions;

CREATE OR REPLACE TEMP TABLE cust_merge_source AS
WITH source_rows AS (
  SELECT *, FALSE AS is_removed FROM new_versions
  UNION ALL
  SELECT d.* EXCLUDE (created_at, updated_at), TRUE AS is_removed
  FROM heyrcg_mart.dim_customer AS d
  WHERE d.customer_id IN (SELECT customer_id FROM affected_customers)
    AND d.customer_key NOT IN (SELECT customer_key FROM new_versions)
)
SELECT s.*,
  CASE
    WHEN s.is_removed             THEN 'DELETE'
    WHEN t.customer_key IS NULL   THEN 'INSERT'
    WHEN t.row_hash != s.row_hash THEN 'UPDATE'
    ELSE 'UNCHANGED'
  END AS change_type
FROM source_rows AS s
LEFT JOIN heyrcg_mart.dim_customer AS t ON t.customer_key = s.customer_key;

MERGE INTO heyrcg_mart.dim_customer AS T
USING cust_merge_source AS S
ON T.customer_key = S.customer_key
WHEN MATCHED AND S.change_type = 'DELETE' THEN DELETE
WHEN MATCHED AND S.change_type = 'UPDATE' THEN UPDATE SET
  full_name = S.full_name, email = S.email, phone = S.phone, city = S.city,
  nationality = S.nationality, joined_date = S.joined_date, loyalty_tier = S.loyalty_tier,
  valid_from = S.valid_from, valid_to = S.valid_to, is_current = S.is_current,
  is_inferred = S.is_inferred, source_updated_at = S.source_updated_at,
  row_hash = S.row_hash, updated_at = current_timestamp
WHEN NOT MATCHED BY TARGET AND S.change_type = 'INSERT' THEN INSERT
  (customer_key, customer_id, full_name, email, phone, city, nationality, joined_date,
   loyalty_tier, valid_from, valid_to, is_current, is_inferred, source_updated_at, row_hash,
   created_at, updated_at)
VALUES
  (S.customer_key, S.customer_id, S.full_name, S.email, S.phone, S.city, S.nationality,
   S.joined_date, S.loyalty_tier, S.valid_from, S.valid_to, S.is_current, S.is_inferred,
   S.source_updated_at, S.row_hash, current_timestamp, current_timestamp);

-- 2. BOOKINGS -------------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE book_candidates AS
SELECT * FROM heyrcg_stg.stg_bookings
WHERE NOT is_snapshot_row AND row_ts > :wm_bookings;

CREATE OR REPLACE TEMP TABLE book_batch AS
SELECT * FROM book_candidates
WHERE quarantine_reason IS NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY booking_id ORDER BY row_ts DESC, row_hash) = 1;

INSERT INTO heyrcg_mart.dim_customer
  (customer_key, customer_id, full_name, email, phone, city, nationality, joined_date,
   loyalty_tier, valid_from, valid_to, is_current, is_inferred, source_updated_at, row_hash,
   created_at, updated_at)
SELECT *, {customer_row_hash}, current_timestamp, current_timestamp
FROM (
  SELECT
    farm_fingerprint(customer_id || '|1900-01-01 00:00:00') AS customer_key,
    customer_id,
    CAST(NULL AS VARCHAR) AS full_name, CAST(NULL AS VARCHAR) AS email, CAST(NULL AS VARCHAR) AS phone,
    CAST(NULL AS VARCHAR) AS city, CAST(NULL AS VARCHAR) AS nationality, CAST(NULL AS DATE) AS joined_date,
    CAST(NULL AS VARCHAR) AS loyalty_tier,
    TIMESTAMP '1900-01-01 00:00:00' AS valid_from, TIMESTAMP '9999-12-31 23:59:59' AS valid_to,
    TRUE AS is_current, TRUE AS is_inferred, CAST(NULL AS TIMESTAMP) AS source_updated_at
  FROM (SELECT DISTINCT customer_id FROM book_batch WHERE customer_id IS NOT NULL) AS b
  WHERE NOT EXISTS (SELECT 1 FROM heyrcg_mart.dim_customer AS d WHERE d.customer_id = b.customer_id)
);

CREATE OR REPLACE TEMP TABLE book_merge_source AS
WITH keyed AS (
  SELECT
    farm_fingerprint(b.booking_id) AS booking_key,
    b.booking_id,
    COALESCE(h.hotel_key, -1) AS hotel_key,
    COALESCE(c.customer_key, -1) AS customer_key,
    CAST(strftime(b.check_in_date, '%Y%m%d') AS BIGINT) AS check_in_date_key,
    CAST(strftime(b.check_out_date, '%Y%m%d') AS BIGINT) AS check_out_date_key,
    CAST(strftime(b.booking_created_date, '%Y%m%d') AS BIGINT) AS booking_date_key,
    b.check_in_date, b.booking_created_date, b.customer_id, b.room_type, b.channel,
    b.booking_source, b.booking_status, b.currency, b.rate_per_night, b.nights,
    b.discount_pct, b.is_loyalty_member, b.room_revenue_idr, b.recognised_room_revenue_idr,
    b.is_revenue_derived, b.date_fix,
    b.row_ts AS source_updated_at, b.source_file, b.row_hash
  FROM book_batch AS b
  LEFT JOIN heyrcg_mart.dim_hotel AS h ON h.hotel_code = b.hotel_code
  LEFT JOIN heyrcg_mart.dim_customer AS c
    ON  c.customer_id = b.customer_id
    AND CAST(b.booking_created_date AS TIMESTAMP) >= c.valid_from
    AND CAST(b.booking_created_date AS TIMESTAMP) <  c.valid_to
)
SELECT k.*,
  CASE
    WHEN t.booking_id IS NULL                                                   THEN 'INSERT'
    WHEN k.source_updated_at > t.source_updated_at AND k.row_hash != t.row_hash THEN 'UPDATE'
    WHEN k.source_updated_at > t.source_updated_at                              THEN 'TOUCH'
    ELSE 'IGNORED_OLDER'
  END AS change_type
FROM keyed AS k
LEFT JOIN heyrcg_mart.fact_bookings AS t ON t.booking_id = k.booking_id;

MERGE INTO heyrcg_mart.fact_bookings AS T
USING book_merge_source AS S
ON T.booking_id = S.booking_id
WHEN MATCHED AND S.change_type IN ('UPDATE', 'TOUCH') THEN UPDATE SET
  hotel_key = S.hotel_key, customer_key = S.customer_key,
  check_in_date_key = S.check_in_date_key, check_out_date_key = S.check_out_date_key,
  booking_date_key = S.booking_date_key, check_in_date = S.check_in_date,
  booking_created_date = S.booking_created_date, customer_id = S.customer_id,
  room_type = S.room_type, channel = S.channel, booking_source = S.booking_source,
  booking_status = S.booking_status, currency = S.currency, rate_per_night = S.rate_per_night,
  nights = S.nights, discount_pct = S.discount_pct, is_loyalty_member = S.is_loyalty_member,
  room_revenue_idr = S.room_revenue_idr, recognised_room_revenue_idr = S.recognised_room_revenue_idr,
  is_revenue_derived = S.is_revenue_derived, date_fix = S.date_fix,
  source_updated_at = S.source_updated_at, source_file = S.source_file, row_hash = S.row_hash,
  updated_at = CASE WHEN S.change_type = 'UPDATE' THEN current_timestamp ELSE T.updated_at END
WHEN NOT MATCHED BY TARGET AND S.change_type = 'INSERT' THEN INSERT
  (booking_key, booking_id, hotel_key, customer_key, check_in_date_key, check_out_date_key,
   booking_date_key, check_in_date, booking_created_date, customer_id, room_type, channel,
   booking_source, booking_status, currency, rate_per_night, nights, discount_pct,
   is_loyalty_member, room_revenue_idr, recognised_room_revenue_idr, is_revenue_derived,
   date_fix, source_updated_at, source_file, row_hash, created_at, updated_at)
VALUES
  (S.booking_key, S.booking_id, S.hotel_key, S.customer_key, S.check_in_date_key,
   S.check_out_date_key, S.booking_date_key, S.check_in_date, S.booking_created_date,
   S.customer_id, S.room_type, S.channel, S.booking_source, S.booking_status, S.currency,
   S.rate_per_night, S.nights, S.discount_pct, S.is_loyalty_member, S.room_revenue_idr,
   S.recognised_room_revenue_idr, S.is_revenue_derived, S.date_fix, S.source_updated_at,
   S.source_file, S.row_hash, current_timestamp, current_timestamp);

-- 3. Re-point facts of affected customers ---------------------------------------------------
UPDATE heyrcg_mart.fact_bookings AS f
SET customer_key = d.customer_key, updated_at = current_timestamp
FROM heyrcg_mart.dim_customer AS d
WHERE d.customer_id = f.customer_id
  AND CAST(f.booking_created_date AS TIMESTAMP) >= d.valid_from
  AND CAST(f.booking_created_date AS TIMESTAMP) <  d.valid_to
  AND f.customer_key != d.customer_key
  AND f.customer_id IN (SELECT customer_id FROM affected_customers);

UPDATE heyrcg_mart.fact_pos_transactions AS f
SET customer_key = d.customer_key, updated_at = current_timestamp
FROM heyrcg_mart.dim_customer AS d
WHERE d.customer_id = f.customer_id
  AND CAST(f.transaction_date AS TIMESTAMP) >= d.valid_from
  AND CAST(f.transaction_date AS TIMESTAMP) <  d.valid_to
  AND f.customer_key != d.customer_key
  AND f.customer_id IN (SELECT customer_id FROM affected_customers);

-- 4. Watermarks (forward only), manifest, run log -------------------------------------------
UPDATE heyrcg_audit.etl_watermark
SET watermark_ts = (SELECT MAX(row_ts) FROM cust_candidates), updated_at = current_timestamp
WHERE source_name = 'customers' AND (SELECT MAX(row_ts) FROM cust_candidates) > watermark_ts;

UPDATE heyrcg_audit.etl_watermark
SET watermark_ts = (SELECT MAX(row_ts) FROM book_candidates), updated_at = current_timestamp
WHERE source_name = 'bookings' AND (SELECT MAX(row_ts) FROM book_candidates) > watermark_ts;

UPDATE heyrcg_raw.file_manifest
SET processed_at = current_timestamp
WHERE processed_at IS NULL
  AND file_name IN (SELECT source_file FROM cust_candidates UNION SELECT source_file FROM book_candidates);

INSERT INTO heyrcg_audit.etl_run_log
SELECT current_timestamp, 'customers', :stored_wm_customers,
  (SELECT watermark_ts FROM heyrcg_audit.etl_watermark WHERE source_name = 'customers'), :is_backfill,
  (SELECT COUNT(*) FROM cust_candidates),
  (SELECT COUNT(*) FILTER (WHERE quarantine_reason IS NOT NULL) FROM cust_candidates),
  (SELECT COUNT(*) FROM affected_customers),
  (SELECT COUNT(*) FILTER (WHERE change_type = 'INSERT') FROM cust_merge_source),
  (SELECT COUNT(*) FILTER (WHERE change_type = 'UPDATE') FROM cust_merge_source),
  (SELECT COUNT(*) FILTER (WHERE change_type = 'DELETE') FROM cust_merge_source),
  current_timestamp, current_timestamp
UNION ALL
SELECT current_timestamp, 'bookings', :stored_wm_bookings,
  (SELECT watermark_ts FROM heyrcg_audit.etl_watermark WHERE source_name = 'bookings'), :is_backfill,
  (SELECT COUNT(*) FROM book_candidates),
  (SELECT COUNT(*) FILTER (WHERE quarantine_reason IS NOT NULL) FROM book_candidates),
  (SELECT COUNT(*) FROM book_batch),
  (SELECT COUNT(*) FILTER (WHERE change_type = 'INSERT') FROM book_merge_source),
  (SELECT COUNT(*) FILTER (WHERE change_type IN ('UPDATE', 'TOUCH')) FROM book_merge_source),
  0,
  current_timestamp, current_timestamp;
