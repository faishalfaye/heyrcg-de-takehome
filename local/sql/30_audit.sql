-- Port of definitions/audit/*.sqlx
CREATE OR REPLACE TABLE heyrcg_audit.etl_watermark AS
SELECT source_name, :snapshot_ts AS watermark_ts, current_timestamp AS created_at, current_timestamp AS updated_at
FROM (VALUES ('bookings'), ('customers')) AS v(source_name);

UPDATE heyrcg_raw.file_manifest
SET processed_at = current_timestamp
WHERE processed_at IS NULL
  AND file_name IN ('raw_bookings.csv', 'raw_customers.csv', 'raw_pos_transactions.csv', 'raw_marketing_performance.csv');

CREATE OR REPLACE TABLE heyrcg_audit.etl_run_log (
  run_ts TIMESTAMPTZ, source_name VARCHAR, watermark_before TIMESTAMP, watermark_after TIMESTAMP,
  is_backfill BOOLEAN, rows_newer_than_wm BIGINT, rows_quarantined BIGINT, rows_in_batch BIGINT,
  rows_inserted BIGINT, rows_updated BIGINT, rows_deleted BIGINT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
);

CREATE OR REPLACE TABLE heyrcg_audit.customer_change_log AS
SELECT customer_id, full_name, email, phone, city, nationality, joined_date, loyalty_tier,
       row_ts, row_hash, source_file, source_row,
       current_timestamp AS created_at, current_timestamp AS updated_at
FROM heyrcg_stg.stg_customers_snapshot;
