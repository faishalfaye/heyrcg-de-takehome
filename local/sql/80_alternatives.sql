-- What the numbers would be under the other option of each judgement call (README, section
-- "Assumptions"). Runs on the mart after the increment. One row per (decision, metric, hotel);
-- hotel = 'All hotels' is the total. run_local.py saves it as local/output/assumption_alternatives.csv.
WITH
bookings AS (
  SELECT f.*, h.hotel_name
  FROM heyrcg_mart.fact_bookings AS f JOIN heyrcg_mart.dim_hotel AS h USING (hotel_key)
),
march_bookings AS (
  SELECT * FROM bookings WHERE check_in_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31'
),
-- the source row each booking in the mart came from (to see its raw status spelling)
winning_rows AS (
  SELECT f.booking_id, s.booking_status_raw
  FROM heyrcg_mart.fact_bookings AS f
  JOIN heyrcg_stg.stg_bookings AS s ON s.booking_id = f.booking_id AND s.row_hash = f.row_hash AND s.row_ts = f.source_updated_at
),
fx AS (SELECT currency, idr_per_unit FROM heyrcg_stg.ref_fx_rate),
pos AS (
  SELECT f.*, h.hotel_name FROM heyrcg_mart.fact_pos_transactions AS f JOIN heyrcg_mart.dim_hotel AS h USING (hotel_key)
),
march_pos AS (SELECT * FROM pos WHERE transaction_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31'),

-- K2 -----------------------------------------------------------------------------------------
k2 AS (
  SELECT hotel_name,
    SUM(CASE WHEN check_in_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31' THEN recognised_room_revenue_idr ELSE 0 END) AS chosen,
    SUM(recognised_room_revenue_idr * GREATEST(0, date_diff('day',
          GREATEST(check_in_date, DATE '2024-03-01'),
          LEAST(check_in_date + CAST(nights AS INTEGER), DATE '2024-04-01'))) / nights) AS alternative
  FROM bookings GROUP BY 1
),
-- K3 -----------------------------------------------------------------------------------------
k3 AS (
  SELECT b.hotel_name, 0 AS chosen,
    COUNT(*) FILTER (WHERE COALESCE(CASE WHEN at_created.is_inferred THEN 'INFERRED' ELSE at_created.loyalty_tier END, 'NONE')
                     != COALESCE(CASE WHEN at_check_in.is_inferred THEN 'INFERRED' ELSE at_check_in.loyalty_tier END, 'NONE')) AS alternative
  FROM bookings AS b
  JOIN heyrcg_mart.dim_customer AS at_created ON at_created.customer_key = b.customer_key
  JOIN heyrcg_mart.dim_customer AS at_check_in
    ON  at_check_in.customer_id = b.customer_id
    AND CAST(b.check_in_date AS TIMESTAMP) >= at_check_in.valid_from
    AND CAST(b.check_in_date AS TIMESTAMP) <  at_check_in.valid_to
  WHERE b.customer_key != -1
  GROUP BY 1
),
-- K4 -----------------------------------------------------------------------------------------
k4_rows AS (
  SELECT b.*, b.rate_per_night * b.nights * fx.idr_per_unit AS gross_at_pms_rate,
         COALESCE(b.discount_pct, 0) AS disc
  FROM march_bookings AS b JOIN fx USING (currency)
),
k4 AS (
  SELECT hotel_name,
    SUM(recognised_room_revenue_idr) AS chosen,
    -- all net: initial-file amounts (gross) get the discount; delta amounts are net already
    SUM(CASE WHEN source_file LIKE 'raw_%' THEN recognised_room_revenue_idr * (1 - disc)
             ELSE recognised_room_revenue_idr END) AS alt_net,
    -- all gross: delta amounts that are net get the discount taken off again
    SUM(CASE WHEN source_file LIKE 'delta_%' AND disc > 0
              AND abs(recognised_room_revenue_idr / gross_at_pms_rate - (1 - disc))
                < abs(recognised_room_revenue_idr / gross_at_pms_rate - 1)
             THEN recognised_room_revenue_idr / (1 - disc)
             ELSE recognised_room_revenue_idr END) AS alt_gross
  FROM k4_rows GROUP BY 1
),
-- K5 -----------------------------------------------------------------------------------------
k5 AS (
  SELECT hotel_name, SUM(recognised_room_revenue_idr) AS chosen, SUM(room_revenue_idr) AS alternative
  FROM march_bookings GROUP BY 1
),
-- K6 -----------------------------------------------------------------------------------------
k6_rows AS (
  SELECT customer_key FROM heyrcg_mart.dim_customer
  WHERE loyalty_tier IS NULL AND NOT is_current AND NOT is_inferred AND customer_key != -1
),
k6 AS (
  SELECT 'All hotels' AS hotel_name, 'dim_customer rows' AS metric,
         (SELECT COUNT(*) FROM heyrcg_mart.dim_customer) AS chosen,
         (SELECT COUNT(*) FROM heyrcg_mart.dim_customer) - (SELECT COUNT(*) FROM k6_rows) AS alternative
  UNION ALL
  SELECT 'All hotels', 'bookings whose loyalty tier label differs', 0,
         (SELECT COUNT(*) FROM heyrcg_mart.fact_bookings WHERE customer_key IN (SELECT customer_key FROM k6_rows))
),
-- K7 -----------------------------------------------------------------------------------------
k7 AS (
  SELECT b.hotel_name, SUM(b.recognised_room_revenue_idr) AS chosen,
         SUM(CASE WHEN lower(trim(w.booking_status_raw)) = 'completed' THEN 0 ELSE b.recognised_room_revenue_idr END) AS alternative,
         COUNT(*) FILTER (WHERE lower(trim(w.booking_status_raw)) = 'completed') AS completed_bookings
  FROM march_bookings AS b JOIN winning_rows AS w USING (booking_id)
  GROUP BY 1
),
-- K9 -----------------------------------------------------------------------------------------
in_house AS (
  SELECT hotel_name, COUNT(DISTINCT customer_id) AS guests
  FROM bookings
  WHERE booking_status NOT IN ('CANCELLED', 'NO_SHOW') AND customer_id IS NOT NULL
    AND check_in_date < DATE '2024-04-01' AND check_in_date + CAST(nights AS INTEGER) > DATE '2024-03-01'
  GROUP BY 1
),
k9_hotel AS (
  SELECT p.hotel_name,
    SUM(CASE WHEN p.customer_id IS NOT NULL THEN p.total_amount_idr ELSE 0 END) AS guest_fnb,
    COUNT(DISTINCT p.customer_id) AS pos_guests,
    SUM(p.total_amount_idr) AS all_fnb,
    MAX(i.guests) AS in_house_guests
  FROM march_pos AS p LEFT JOIN in_house AS i USING (hotel_name)
  GROUP BY 1
),
k9 AS (
  SELECT hotel_name, guest_fnb / pos_guests AS chosen, all_fnb / in_house_guests AS alternative FROM k9_hotel
  UNION ALL
  SELECT 'All hotels', SUM(guest_fnb) / SUM(pos_guests), SUM(all_fnb) / SUM(in_house_guests) FROM k9_hotel
),
-- POS dates: one rule (day-first) for both NN-NN-YYYY and NN/NN/YYYY ---------------------------
pos_dates AS (
  SELECT s.*, h.hotel_name,
    CASE WHEN regexp_matches(s.transaction_date_raw, '^\d{2}-\d{2}-\d{4}$')
         THEN try_strptime(s.transaction_date_raw, '%d-%m-%Y')::DATE ELSE s.transaction_date END AS day_first_date
  FROM heyrcg_stg.stg_pos_transactions AS s JOIN heyrcg_mart.dim_hotel AS h USING (hotel_code)
  WHERE s.quarantine_reason IS NULL AND s.duplicate_rank = 1
),
pos_date_alt AS (
  SELECT hotel_name,
    SUM(CASE WHEN transaction_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31' THEN total_amount_idr ELSE 0 END) AS chosen,
    SUM(CASE WHEN day_first_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31' THEN total_amount_idr ELSE 0 END) AS alternative,
    COUNT(*) FILTER (WHERE day_first_date IS NULL) AS unparseable,
    COUNT(*) FILTER (WHERE day_first_date != transaction_date) AS moved
  FROM pos_dates GROUP BY 1
),
-- Check-out repair and empty revenue: quarantine instead of repair -----------------------------
repairs AS (
  SELECT hotel_name, SUM(recognised_room_revenue_idr) AS chosen,
    SUM(CASE WHEN date_fix IS NULL THEN recognised_room_revenue_idr ELSE 0 END) AS alt_no_date_repair,
    SUM(CASE WHEN NOT is_revenue_derived THEN recognised_room_revenue_idr ELSE 0 END) AS alt_no_revenue_repair
  FROM march_bookings GROUP BY 1
),
-- POS duplicates kept ------------------------------------------------------------------------
pos_dups AS (
  SELECT h.hotel_name, SUM(s.total_amount_idr) AS dup_amount
  FROM heyrcg_stg.stg_pos_transactions AS s JOIN heyrcg_mart.dim_hotel AS h USING (hotel_code)
  WHERE s.quarantine_reason IS NULL AND s.duplicate_rank > 1
    AND s.transaction_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31'
  GROUP BY 1
),
pos_dup_alt AS (
  SELECT p.hotel_name, SUM(p.total_amount_idr) AS chosen, SUM(p.total_amount_idr) + COALESCE(MAX(d.dup_amount), 0) AS alternative
  FROM march_pos AS p LEFT JOIN pos_dups AS d USING (hotel_name) GROUP BY 1
),

long AS (
  SELECT 'K2' AS decision, 'March room revenue (IDR)' AS metric, 'check-in month' AS chosen_option,
         'split by nights in March' AS alternative_option, hotel_name, chosen, alternative FROM k2
  UNION ALL
  SELECT 'K3', 'bookings whose loyalty tier label differs', 'tier at booking created_at',
         'tier at check-in date', hotel_name, chosen, alternative FROM k3
  UNION ALL
  SELECT 'K4', 'March room revenue (IDR)', 'PMS amount as given', 'everything net of discount_pct',
         hotel_name, chosen, alt_net FROM k4
  UNION ALL
  SELECT 'K4', 'March room revenue (IDR)', 'PMS amount as given', 'everything gross (before discount)',
         hotel_name, chosen, alt_gross FROM k4
  UNION ALL
  SELECT 'K5', 'March room revenue (IDR)', 'cancelled / no-show = 0', 'cancelled / no-show at PMS amount',
         hotel_name, chosen, alternative FROM k5
  UNION ALL
  SELECT 'K6', metric, 'no tier -> tier is a new version', 'no tier -> tier is a Type 1 fill',
         hotel_name, chosen, alternative FROM k6
  UNION ALL
  SELECT 'K7', 'March room revenue (IDR)', 'completed = CHECKED_OUT', 'completed quarantined (unknown status)',
         hotel_name, chosen, alternative FROM k7
  UNION ALL
  SELECT 'K9', 'March F&B revenue per guest (IDR)', 'guest F&B / guests seen on POS',
         'all F&B / in-house guests (bookings)', hotel_name, chosen, alternative FROM k9
  UNION ALL
  SELECT 'D3 POS dates', 'March F&B revenue (IDR)', 'NN-NN-YYYY month-first, NN/NN/YYYY day-first',
         'day-first for both', hotel_name, chosen, alternative FROM pos_date_alt
  UNION ALL
  SELECT 'D3 check-out', 'March room revenue (IDR)', 'repair 122 bookings using nights', 'quarantine them',
         hotel_name, chosen, alt_no_date_repair FROM repairs
  UNION ALL
  SELECT 'D3 revenue', 'March room revenue (IDR)', 'derive 140 empty amounts from rate x nights', 'quarantine them',
         hotel_name, chosen, alt_no_revenue_repair FROM repairs
  UNION ALL
  SELECT 'D4 POS duplicates', 'March F&B revenue (IDR)', 'remove 340 exact copies', 'keep them',
         hotel_name, chosen, alternative FROM pos_dup_alt
),
with_totals AS (
  SELECT * FROM long
  UNION ALL
  -- totals for the per-hotel sums (K6 and K9 already have their own 'All hotels' row)
  SELECT decision, metric, chosen_option, alternative_option, 'All hotels', SUM(chosen), SUM(alternative)
  FROM long WHERE decision NOT IN ('K6', 'K9')
  GROUP BY 1, 2, 3, 4
)
SELECT decision, metric, chosen_option, alternative_option, hotel_name,
       ROUND(CAST(chosen AS DECIMAL(38, 9)), 0) AS chosen_value,
       ROUND(CAST(alternative AS DECIMAL(38, 9)), 0) AS alternative_value,
       ROUND(CAST(alternative AS DECIMAL(38, 9)) - CAST(chosen AS DECIMAL(38, 9)), 0) AS difference,
       ROUND(100 * (CAST(alternative AS DOUBLE) / NULLIF(CAST(chosen AS DOUBLE), 0) - 1), 1) AS difference_pct
FROM with_totals
ORDER BY decision, alternative_option, hotel_name = 'All hotels' DESC, hotel_name;
