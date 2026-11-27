-- Port of definitions/tests/*.sqlx. run_local.py splits this file on the "-- name:" lines and
-- runs each query; an assertion passes when it returns no rows. "-- tags:" says when it runs
-- (initial = after the initial build, incremental = after every incremental run), as in Dataform.

-- name: assert_dim_customer_scd2
-- tags: initial incremental
WITH v AS (
  SELECT
    customer_key, customer_id, valid_from, valid_to, is_current,
    LEAD(valid_from) OVER (PARTITION BY customer_id ORDER BY valid_from) AS next_from,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY valid_from) AS rn,
    COUNT(*) OVER (PARTITION BY customer_key) AS key_count
  FROM heyrcg_mart.dim_customer
)
SELECT customer_id, 'not exactly one current version' AS problem
FROM v GROUP BY customer_id HAVING count_if(is_current) != 1
UNION ALL
SELECT customer_id, 'gap or overlap between versions' FROM v WHERE next_from IS NOT NULL AND valid_to != next_from
UNION ALL
SELECT customer_id, 'last version is not open-ended' FROM v WHERE next_from IS NULL AND valid_to != TIMESTAMP '9999-12-31 23:59:59'
UNION ALL
SELECT customer_id, 'is_current does not match valid_to' FROM v WHERE is_current != (valid_to = TIMESTAMP '9999-12-31 23:59:59')
UNION ALL
SELECT customer_id, 'first version does not start in 1900' FROM v WHERE rn = 1 AND valid_from != TIMESTAMP '1900-01-01 00:00:00'
UNION ALL
SELECT customer_id, 'valid_from >= valid_to' FROM v WHERE valid_from >= valid_to
UNION ALL
SELECT customer_id, 'duplicate customer_key' FROM v WHERE key_count > 1;

-- name: assert_fact_integrity
-- tags: initial incremental
SELECT 'fact_bookings' AS fact, booking_id AS business_key, 'duplicate booking_id' AS problem
FROM heyrcg_mart.fact_bookings GROUP BY booking_id HAVING COUNT(*) > 1
UNION ALL
SELECT 'fact_pos_transactions', pos_line_id, 'duplicate pos_line_id'
FROM heyrcg_mart.fact_pos_transactions GROUP BY pos_line_id HAVING COUNT(*) > 1
UNION ALL
SELECT 'fact_bookings', f.booking_id, 'hotel_key not in dim_hotel'
FROM heyrcg_mart.fact_bookings AS f LEFT JOIN heyrcg_mart.dim_hotel AS h ON h.hotel_key = f.hotel_key WHERE h.hotel_key IS NULL
UNION ALL
SELECT 'fact_bookings', f.booking_id, 'date key not in dim_date'
FROM heyrcg_mart.fact_bookings AS f
WHERE f.check_in_date_key  NOT IN (SELECT date_key FROM heyrcg_mart.dim_date)
   OR f.check_out_date_key NOT IN (SELECT date_key FROM heyrcg_mart.dim_date)
   OR f.booking_date_key   NOT IN (SELECT date_key FROM heyrcg_mart.dim_date)
UNION ALL
SELECT 'fact_bookings', f.booking_id, 'customer_key not in dim_customer'
FROM heyrcg_mart.fact_bookings AS f LEFT JOIN heyrcg_mart.dim_customer AS c ON c.customer_key = f.customer_key WHERE c.customer_key IS NULL
UNION ALL
SELECT 'fact_bookings', f.booking_id, 'customer version not valid on booking date'
FROM heyrcg_mart.fact_bookings AS f JOIN heyrcg_mart.dim_customer AS c USING (customer_key)
WHERE f.customer_key != -1
  AND NOT (CAST(f.booking_created_date AS TIMESTAMP) >= c.valid_from AND CAST(f.booking_created_date AS TIMESTAMP) < c.valid_to)
UNION ALL
SELECT 'fact_bookings', f.booking_id, 'known customer_id but unknown customer_key'
FROM heyrcg_mart.fact_bookings AS f WHERE f.customer_id IS NOT NULL AND f.customer_key = -1
UNION ALL
SELECT 'fact_pos_transactions', f.pos_line_id, 'hotel_key not in dim_hotel'
FROM heyrcg_mart.fact_pos_transactions AS f LEFT JOIN heyrcg_mart.dim_hotel AS h ON h.hotel_key = f.hotel_key WHERE h.hotel_key IS NULL
UNION ALL
SELECT 'fact_pos_transactions', f.pos_line_id, 'date key not in dim_date'
FROM heyrcg_mart.fact_pos_transactions AS f WHERE f.transaction_date_key NOT IN (SELECT date_key FROM heyrcg_mart.dim_date)
UNION ALL
SELECT 'fact_pos_transactions', f.pos_line_id, 'customer version not valid on transaction date'
FROM heyrcg_mart.fact_pos_transactions AS f JOIN heyrcg_mart.dim_customer AS c USING (customer_key)
WHERE f.customer_key != -1
  AND NOT (CAST(f.transaction_date AS TIMESTAMP) >= c.valid_from AND CAST(f.transaction_date AS TIMESTAMP) < c.valid_to)
UNION ALL
SELECT 'fact_pos_transactions', f.pos_line_id, 'known customer_id but unknown customer_key'
FROM heyrcg_mart.fact_pos_transactions AS f WHERE f.customer_id IS NOT NULL AND f.customer_key = -1;

-- name: assert_nothing_lost
-- tags: initial incremental
WITH raw_counts AS (
  SELECT _source_file AS file_name, COUNT(*) AS n FROM heyrcg_raw.bookings GROUP BY 1
  UNION ALL SELECT _source_file, COUNT(*) FROM heyrcg_raw.customers GROUP BY 1
  UNION ALL SELECT _source_file, COUNT(*) FROM heyrcg_raw.pos_transactions GROUP BY 1
)
SELECT m.file_name AS item, printf('manifest %d rows, raw table %d rows', m.row_count, COALESCE(r.n, 0)) AS problem
FROM heyrcg_raw.file_manifest AS m
LEFT JOIN raw_counts AS r ON r.file_name = m.file_name
WHERE m.source_name IN ('bookings', 'customers', 'pos_transactions') AND m.row_count != COALESCE(r.n, 0)
UNION ALL
SELECT 'pos_transactions', printf('raw %d != fact %d + quarantined %d + duplicates %d', raw_n, fact_n, quar_n, dup_n)
FROM (
  SELECT
    (SELECT COUNT(*) FROM heyrcg_raw.pos_transactions) AS raw_n,
    (SELECT COUNT(*) FROM heyrcg_mart.fact_pos_transactions) AS fact_n,
    (SELECT COUNT(*) FROM heyrcg_stg.stg_pos_transactions WHERE quarantine_reason IS NOT NULL) AS quar_n,
    (SELECT COUNT(*) FROM heyrcg_stg.stg_pos_transactions WHERE quarantine_reason IS NULL AND duplicate_rank > 1) AS dup_n
)
WHERE raw_n != fact_n + quar_n + dup_n
UNION ALL
SELECT 'customers', printf('raw %d != kept %d + duplicates %d + quarantined %d', raw_n, kept_n, dup_n, quar_n)
FROM (
  SELECT
    (SELECT COUNT(*) FROM heyrcg_stg.stg_customers WHERE is_snapshot_row) AS raw_n,
    (SELECT COUNT(*) FROM heyrcg_stg.stg_customers_snapshot) AS kept_n,
    (SELECT COUNT(*) FROM heyrcg_stg.stg_quarantine WHERE source_name = 'customers' AND action = 'DUPLICATE_REMOVED') AS dup_n,
    (SELECT COUNT(*) FROM heyrcg_stg.stg_customers WHERE is_snapshot_row AND quarantine_reason IS NOT NULL) AS quar_n
)
WHERE raw_n != kept_n + dup_n + quar_n
UNION ALL
SELECT b.booking_id, 'valid initial booking missing from fact_bookings'
FROM heyrcg_stg.stg_bookings AS b
LEFT JOIN heyrcg_mart.fact_bookings AS f ON f.booking_id = b.booking_id
WHERE b.is_snapshot_row AND b.quarantine_reason IS NULL AND f.booking_id IS NULL
UNION ALL
SELECT pos_line_id, 'same pos_transaction_id with different content'
FROM heyrcg_stg.stg_pos_transactions
GROUP BY pos_line_id
HAVING COUNT(DISTINCT row_hash) > 1;

-- name: assert_incremental_equals_recompute
-- tags: incremental
WITH recomputed AS (
  SELECT booking_id, booking_status, check_in_date, nights, recognised_room_revenue_idr, hotel_code
  FROM heyrcg_stg.stg_bookings
  WHERE quarantine_reason IS NULL
    AND (is_snapshot_row OR row_ts > :snapshot_ts)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY booking_id ORDER BY row_ts DESC, row_hash) = 1
),
mart AS (
  SELECT f.booking_id, f.booking_status, f.check_in_date, f.nights, f.recognised_room_revenue_idr, h.hotel_code
  FROM heyrcg_mart.fact_bookings AS f
  JOIN heyrcg_mart.dim_hotel AS h USING (hotel_key)
)
SELECT
  COALESCE(r.booking_id, m.booking_id) AS item,
  printf('recompute=%s|%s|%s|%s | mart=%s|%s|%s|%s',
         r.booking_status, r.check_in_date, r.nights, r.recognised_room_revenue_idr,
         m.booking_status, m.check_in_date, m.nights, m.recognised_room_revenue_idr) AS problem
FROM recomputed AS r
FULL OUTER JOIN mart AS m ON m.booking_id = r.booking_id
WHERE r.booking_id IS NULL OR m.booking_id IS NULL
   OR r.booking_status != m.booking_status
   OR r.check_in_date != m.check_in_date
   OR r.nights != m.nights
   OR r.recognised_room_revenue_idr != m.recognised_room_revenue_idr
UNION ALL
SELECT 'March 2024 revenue ' || hotel_code, printf('recompute=%s | mart=%s', r_rev, m_rev)
FROM (
  SELECT hotel_code,
         SUM(CASE WHEN src = 'r' THEN rev ELSE 0 END) AS r_rev,
         SUM(CASE WHEN src = 'm' THEN rev ELSE 0 END) AS m_rev
  FROM (
    SELECT 'r' AS src, hotel_code, recognised_room_revenue_idr AS rev, check_in_date FROM recomputed
    UNION ALL
    SELECT 'm', hotel_code, recognised_room_revenue_idr, check_in_date FROM mart
  )
  WHERE check_in_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31'
  GROUP BY hotel_code
)
WHERE r_rev != m_rev;

-- name: expected_outcomes
-- tags: incremental
WITH
booking_actual AS (
  SELECT
    f.booking_id,
    printf('%s|%s|%d|%s|%s',
      f.booking_status, num_str(f.recognised_room_revenue_idr), f.nights,
      strftime(f.source_updated_at, '%Y-%m-%d %H:%M:%S'),
      COALESCE(CASE WHEN c.is_inferred THEN 'INFERRED' ELSE c.loyalty_tier END, 'NONE')) AS actual
  FROM heyrcg_mart.fact_bookings AS f
  JOIN heyrcg_mart.dim_customer AS c USING (customer_key)
),
customer_actual AS (
  SELECT
    customer_id,
    printf('%s|%s|%s',
      string_agg(COALESCE(CASE WHEN is_inferred THEN 'INFERRED' ELSE loyalty_tier END, 'NONE'), '>' ORDER BY valid_from),
      COALESCE(MAX(CASE WHEN is_current THEN email END), 'NULL'),
      COALESCE(MAX(CASE WHEN is_current THEN phone END), 'NULL')) AS actual
  FROM heyrcg_mart.dim_customer
  GROUP BY customer_id
),
metric_actual AS (
  SELECT 'fact_bookings rows' AS item, CAST(COUNT(*) AS VARCHAR) AS actual FROM heyrcg_mart.fact_bookings
  UNION ALL SELECT 'dim_customer rows', CAST(COUNT(*) AS VARCHAR) FROM heyrcg_mart.dim_customer
  UNION ALL SELECT 'dim_customer inferred members', CAST(count_if(is_inferred) AS VARCHAR) FROM heyrcg_mart.dim_customer
  UNION ALL SELECT 'watermark ' || source_name, strftime(watermark_ts, '%Y-%m-%d %H:%M:%S') FROM heyrcg_audit.etl_watermark
  UNION ALL
  SELECT 'March 2024 revenue ' || h.hotel_code, num_str(ROUND(SUM(f.recognised_room_revenue_idr), 0))
  FROM heyrcg_mart.fact_bookings AS f JOIN heyrcg_mart.dim_hotel AS h USING (hotel_key)
  WHERE f.check_in_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31'
  GROUP BY h.hotel_code
),
booking_expected AS (
  SELECT * FROM (VALUES
    ('BKG-00002', 'CANCELLED|0|6|2024-03-29 09:12:00|Bronze',            'B2 two versions in one file: the later "cnx" row wins'),
    ('BKG-00003', 'CHECKED_OUT|39150734|7|2024-03-29 10:40:00|Silver',   'B4 status update Confirmed -> checked_out'),
    ('BKG-00006', 'CHECKED_OUT|26630805|5|2024-03-29 11:02:00|Bronze',   'B4 status update Confirmed -> Checked Out'),
    ('BKG-00010', 'CHECKED_OUT|21794214|6|2024-03-30 08:20:00|NONE',     'B4 stay extended 4 -> 6 nights, revenue up'),
    ('BKG-00011', 'CANCELLED|0|3|2024-03-30 14:55:00|NONE',              'B4 January booking cancelled after the fact'),
    ('BKG-00012', 'CHECKED_IN|9754688|2|2024-03-28 00:00:00|Bronze',     'B3 row older than the watermark is ignored'),
    ('BKG-00013', 'CHECKED_OUT|29258830.8|6|2024-03-30 16:30:00|NONE',   'B4 "completed" + discount now applied'),
    ('BKG-10004', 'CONFIRMED|722500|1|2024-03-31 11:54:00|Silver',       'B1 exact duplicate row -> one booking'),
    ('BKG-10017', 'CONFIRMED|3600000|1|2024-03-29 11:57:00|NONE',        'B9 booked 03-19, before CUST00001 got Bronze on 03-29'),
    ('BKG-10045', 'CONFIRMED|7200000|2|2024-03-30 14:15:00|Silver',      'B8 customer new in the same batch'),
    ('BKG-10047', 'CONFIRMED|15600000|3|2024-03-30 19:40:00|INFERRED',   'B7 unknown customer CUST19999 -> inferred member'),
    ('BKG-10048', 'CHECKED_OUT|15600000|3|2024-03-29 08:05:00|NONE',     'B5 late-arriving March stay'),
    ('BKG-10049', 'CHECKED_OUT|7200000|2|2024-03-29 09:05:00|NONE',      'B5 late-arriving March stay'),
    ('BKG-10050', 'CHECKED_OUT|19760000|4|2024-03-29 10:05:00|Silver',   'B5 late-arriving March stay')
  ) AS v(booking_id, expected, case_label)
),
customer_expected AS (
  SELECT * FROM (VALUES
    ('CUST00001', 'NONE>Bronze|customer.1@gmail.com|08782090572',          'C7 no tier -> Bronze is a tier change (ASSUMPTION K6)'),
    ('CUST00002', 'Gold|customer.2@hotmail.com|08262365542',               'C5 only the email spelling differs'),
    ('CUST00006', 'Silver>Gold>Platinum|customer.6@gmail.com|08301822108', 'C3 two tier changes in one batch'),
    ('CUST00010', 'Gold>Platinum|customer.10@gmail.com|08797709566',       'C4 rows out of order + exact duplicate + a row that changes nothing'),
    ('CUST00011', 'Bronze|customer.11@gmail.com|08134455667',              'C6 Type 1: phone filled in place, no new version'),
    ('CUST00012', 'Silver>Gold|customer12@yahoo.com|08251078407',          'C2/C8 tier change written as "gold"'),
    ('CUST00016', 'Bronze>Silver|customer16@yahoo.com|08679408548',        'C2 tier change'),
    ('CUST00020', 'Bronze>Silver|customer20@yahoo.com|08169203678',        'C2/C8 tier change written as "SILVER"'),
    ('CUST00024', 'Gold>Platinum|customer.24@gmail.com|08315438018',       'C2 tier change'),
    ('CUST10001', 'Bronze|customer10001@yahoo.com|08858482648',            'C1/C9 new customer, email with spaces and capitals'),
    ('CUST10004', 'Silver|customer.10004@gmail.com|08907991403',           'C1 new customer'),
    ('CUST19999', 'INFERRED|NULL|NULL',                                    'B7 inferred member, not in the CRM')
  ) AS v(customer_id, expected, case_label)
),
metric_expected AS (
  SELECT * FROM (VALUES
    ('fact_bookings rows', '3250', '3,200 initial + 50 new booking ids'),
    ('dim_customer rows', '816', '800 customers + 8 new versions + 6 new customers + 1 inferred + 1 unknown member'),
    ('dim_customer inferred members', '1', 'CUST19999'),
    ('watermark customers', '2024-03-31 18:10:00', 'newest updated_at in delta_customers'),
    ('watermark bookings', '2024-03-31 20:57:00', 'newest updated_at in delta_bookings'),
    ('March 2024 revenue ALAYA_UBUD', '1918090885', '+7,264,738: BKG-00010 extended'),
    ('March 2024 revenue BISMA_EIGHT', '1960167118', '-26,148,480 BKG-00002 cancelled, +7,200,000 BKG-10049'),
    ('March 2024 revenue KATAMAMA_RESORT', '2234059430', 'unchanged'),
    ('March 2024 revenue KOMANEKA_BISMA', '1976391037', 'unchanged'),
    ('March 2024 revenue THE_LAYAR_SEMINYAK', '1745556533', 'unchanged'),
    ('March 2024 revenue THE_MULIA_NUSA_DUA', '2064843376', '+15,600,000 BKG-10048, +19,760,000 BKG-10050')
  ) AS v(item, expected, case_label)
)
SELECT e.case_label, e.booking_id AS item, e.expected, COALESCE(a.actual, 'MISSING') AS actual
FROM booking_expected AS e LEFT JOIN booking_actual AS a ON a.booking_id = e.booking_id
WHERE a.actual IS DISTINCT FROM e.expected
UNION ALL
SELECT e.case_label, e.customer_id, e.expected, COALESCE(a.actual, 'MISSING')
FROM customer_expected AS e LEFT JOIN customer_actual AS a ON a.customer_id = e.customer_id
WHERE a.actual IS DISTINCT FROM e.expected
UNION ALL
SELECT e.case_label, e.item, e.expected, COALESCE(a.actual, 'MISSING')
FROM metric_expected AS e LEFT JOIN metric_actual AS a ON a.item = e.item
WHERE a.actual IS DISTINCT FROM e.expected;
