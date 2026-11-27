-- Port of definitions/reports/*.sqlx
CREATE OR REPLACE VIEW heyrcg_mart.rpt_monthly_revenue_by_hotel AS
WITH rooms AS (
  SELECT d.year_month, f.hotel_key,
         SUM(f.recognised_room_revenue_idr) AS room_revenue_idr,
         COUNT_IF(f.booking_status NOT IN ('CANCELLED', 'NO_SHOW')) AS bookings_counted
  FROM heyrcg_mart.fact_bookings AS f
  JOIN heyrcg_mart.dim_date AS d ON d.date_key = f.check_in_date_key
  GROUP BY 1, 2
),
fnb AS (
  SELECT d.year_month, f.hotel_key, SUM(f.total_amount_idr) AS fnb_revenue_idr
  FROM heyrcg_mart.fact_pos_transactions AS f
  JOIN heyrcg_mart.dim_date AS d ON d.date_key = f.transaction_date_key
  GROUP BY 1, 2
)
SELECT
  year_month, h.hotel_name,
  COALESCE(r.room_revenue_idr, 0) AS room_revenue_idr,
  COALESCE(b.fnb_revenue_idr, 0) AS fnb_revenue_idr,
  COALESCE(r.room_revenue_idr, 0) + COALESCE(b.fnb_revenue_idr, 0) AS total_revenue_idr,
  COALESCE(r.bookings_counted, 0) AS bookings_counted
FROM rooms AS r
FULL OUTER JOIN fnb AS b USING (year_month, hotel_key)
JOIN heyrcg_mart.dim_hotel AS h USING (hotel_key);

CREATE OR REPLACE VIEW heyrcg_mart.rpt_fnb_revenue_per_guest AS
SELECT
  d.year_month, h.hotel_name,
  SUM(CASE WHEN f.customer_id IS NOT NULL THEN f.total_amount_idr ELSE 0 END) AS guest_fnb_revenue_idr,
  COUNT(DISTINCT f.customer_id) AS guests,
  SUM(CASE WHEN f.customer_id IS NOT NULL THEN f.total_amount_idr ELSE 0 END)
    / NULLIF(COUNT(DISTINCT f.customer_id), 0) AS fnb_revenue_per_guest_idr,
  SUM(CASE WHEN f.customer_id IS NULL THEN f.total_amount_idr ELSE 0 END) AS walk_in_fnb_revenue_idr,
  SUM(f.total_amount_idr) AS total_fnb_revenue_idr
FROM heyrcg_mart.fact_pos_transactions AS f
JOIN heyrcg_mart.dim_date AS d ON d.date_key = f.transaction_date_key
JOIN heyrcg_mart.dim_hotel AS h USING (hotel_key)
GROUP BY 1, 2;
