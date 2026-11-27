-- Port of definitions/mart/*.sqlx (initial build)
CREATE OR REPLACE TABLE heyrcg_mart.dim_date AS
SELECT
  CAST(strftime(d, '%Y%m%d') AS BIGINT) AS date_key, d AS full_date, year(d) AS year, quarter(d) AS quarter,
  month(d) AS month, strftime(d, '%B') AS month_name, strftime(d, '%Y-%m') AS year_month,
  day(d) AS day_of_month, dayofweek(d) + 1 AS day_of_week, strftime(d, '%A') AS day_name,
  dayofweek(d) IN (0, 6) AS is_weekend, current_timestamp AS created_at, current_timestamp AS updated_at
FROM (SELECT CAST(unnest(generate_series(DATE '2023-01-01', DATE '2024-12-31', INTERVAL 1 DAY)) AS DATE) AS d)
UNION ALL
SELECT -1, NULL, NULL, NULL, NULL, 'Unknown', 'Unknown', NULL, NULL, 'Unknown', NULL, current_timestamp, current_timestamp;

CREATE OR REPLACE TABLE heyrcg_mart.dim_hotel AS
SELECT farm_fingerprint(hotel_code) AS hotel_key, hotel_code, hotel_name,
       current_timestamp AS created_at, current_timestamp AS updated_at
FROM heyrcg_stg.ref_hotel
UNION ALL
SELECT -1, 'UNKNOWN', 'Unknown hotel', current_timestamp, current_timestamp;

CREATE OR REPLACE TABLE heyrcg_mart.dim_customer AS
WITH
{scd2_all},
inferred AS (
  SELECT DISTINCT customer_id FROM (
    SELECT customer_id FROM heyrcg_stg.stg_bookings
    WHERE is_snapshot_row AND quarantine_reason IS NULL AND customer_id IS NOT NULL
    UNION ALL
    SELECT customer_id FROM heyrcg_stg.stg_pos_transactions
    WHERE quarantine_reason IS NULL AND duplicate_rank = 1 AND customer_id IS NOT NULL
  )
  WHERE customer_id NOT IN (SELECT customer_id FROM customer_versions)
),
all_rows AS (
  SELECT * FROM customer_versions
  UNION ALL
  SELECT farm_fingerprint(customer_id || '|1900-01-01 00:00:00'), customer_id, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, TIMESTAMP '1900-01-01 00:00:00', TIMESTAMP '9999-12-31 23:59:59', TRUE, TRUE, NULL
  FROM inferred
  UNION ALL
  SELECT -1, 'UNKNOWN', 'Unknown customer', NULL, NULL, NULL, NULL, NULL, NULL,
         TIMESTAMP '1900-01-01 00:00:00', TIMESTAMP '9999-12-31 23:59:59', TRUE, FALSE, NULL
)
SELECT *, {customer_row_hash} AS row_hash, current_timestamp AS created_at, current_timestamp AS updated_at
FROM all_rows;

CREATE OR REPLACE TABLE heyrcg_mart.fact_bookings AS
SELECT
  farm_fingerprint(b.booking_id) AS booking_key,
  b.booking_id,
  COALESCE(h.hotel_key, -1) AS hotel_key,
  COALESCE(c.customer_key, -1) AS customer_key,
  CAST(strftime(b.check_in_date, '%Y%m%d') AS BIGINT) AS check_in_date_key,
  CAST(strftime(b.check_out_date, '%Y%m%d') AS BIGINT) AS check_out_date_key,
  CAST(strftime(b.booking_created_date, '%Y%m%d') AS BIGINT) AS booking_date_key,
  b.check_in_date, b.booking_created_date, b.customer_id, b.room_type, b.channel, b.booking_source,
  b.booking_status, b.currency, b.rate_per_night, b.nights, b.discount_pct, b.is_loyalty_member,
  b.room_revenue_idr, b.recognised_room_revenue_idr, b.is_revenue_derived, b.date_fix,
  b.row_ts AS source_updated_at, b.source_file, b.row_hash,
  current_timestamp AS created_at, current_timestamp AS updated_at
FROM heyrcg_stg.stg_bookings AS b
LEFT JOIN heyrcg_mart.dim_hotel AS h ON h.hotel_code = b.hotel_code
LEFT JOIN heyrcg_mart.dim_customer AS c
  ON  c.customer_id = b.customer_id
  AND CAST(b.booking_created_date AS TIMESTAMP) >= c.valid_from
  AND CAST(b.booking_created_date AS TIMESTAMP) <  c.valid_to
WHERE b.is_snapshot_row AND b.quarantine_reason IS NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.booking_id ORDER BY b.row_ts DESC, b.row_hash) = 1;

CREATE OR REPLACE TABLE heyrcg_mart.fact_pos_transactions AS
SELECT
  farm_fingerprint(p.pos_line_id) AS pos_line_key,
  p.pos_line_id,
  COALESCE(h.hotel_key, -1) AS hotel_key,
  COALESCE(c.customer_key, -1) AS customer_key,
  CAST(strftime(p.transaction_date, '%Y%m%d') AS BIGINT) AS transaction_date_key,
  p.transaction_date, p.customer_id, p.outlet_name, p.item_name, p.category, p.payment_method,
  p.payment_type, p.staff_id, p.quantity, p.unit_price_idr, p.total_amount_idr,
  p.is_hotel_inferred, p.is_category_inferred, p.is_unit_price_derived, p.source_file, p.row_hash,
  current_timestamp AS created_at, current_timestamp AS updated_at
FROM heyrcg_stg.stg_pos_transactions AS p
LEFT JOIN heyrcg_mart.dim_hotel AS h ON h.hotel_code = p.hotel_code
LEFT JOIN heyrcg_mart.dim_customer AS c
  ON  c.customer_id = p.customer_id
  AND CAST(p.transaction_date AS TIMESTAMP) >= c.valid_from
  AND CAST(p.transaction_date AS TIMESTAMP) <  c.valid_to
WHERE p.quarantine_reason IS NULL AND p.duplicate_rank = 1;
