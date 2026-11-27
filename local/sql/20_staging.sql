-- Port of definitions/staging/*.sqlx. Same CTE names, same rules, DuckDB functions.
-- Placeholder replaced by run_local.py: :snapshot_ts

-- stg_customers -------------------------------------------------------------------------
CREATE OR REPLACE VIEW heyrcg_stg.stg_customers AS
WITH typed AS (
  SELECT
    _source_file AS source_file,
    _source_row  AS source_row,
    _loaded_at   AS loaded_at,
    NULLIF(UPPER(TRIM(customer_id)), '') AS customer_id,
    NULLIF(TRIM(full_name), '') AS full_name,
    regexp_replace(LOWER(TRIM(email)), '\s+', '.', 'g') AS email_candidate,
    NULLIF(TRIM(phone), '') AS phone,
    NULLIF(TRIM(city), '') AS city,
    NULLIF(TRIM(nationality), '') AS nationality,
    NULLIF(initcap1(TRIM(loyalty_tier)), '') AS loyalty_tier,
    NULLIF(TRIM(joined_date), '') AS joined_date_raw,
    NULLIF(TRIM(updated_at), '') AS updated_at_raw
  FROM heyrcg_raw.customers
),
cleaned AS (
  SELECT
    * EXCLUDE (email_candidate),
    CASE WHEN regexp_matches(email_candidate, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') THEN email_candidate END AS email,
    email_candidate != '' AND NOT regexp_matches(email_candidate, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') AS is_email_invalid,
    try_strptime(joined_date_raw, '%Y-%m-%d')::DATE AS joined_date,
    try_strptime(updated_at_raw, '%Y-%m-%d %H:%M:%S') AS updated_at
  FROM typed
)
SELECT
  source_file, source_row, loaded_at, customer_id, full_name, email, is_email_invalid,
  phone, city, nationality, loyalty_tier, joined_date,
  updated_at_raw IS NULL AS is_snapshot_row,
  COALESCE(updated_at, :snapshot_ts) AS row_ts,
  sha256(to_json(struct_pack(full_name := full_name, email := email, phone := phone, city := city,
    nationality := nationality, joined_date := joined_date, loyalty_tier := loyalty_tier))::VARCHAR) AS row_hash,
  CASE
    WHEN customer_id IS NULL OR NOT regexp_matches(customer_id, '^CUST[0-9]+$') THEN 'INVALID_CUSTOMER_ID'
    WHEN loyalty_tier IS NOT NULL AND loyalty_tier NOT IN ('Bronze', 'Silver', 'Gold', 'Platinum') THEN 'UNKNOWN_LOYALTY_TIER'
    WHEN updated_at_raw IS NOT NULL AND updated_at IS NULL THEN 'INVALID_UPDATED_AT'
  END AS quarantine_reason
FROM cleaned;

-- stg_customers_snapshot ----------------------------------------------------------------
CREATE OR REPLACE VIEW heyrcg_stg.stg_customers_snapshot AS
SELECT *, COUNT(*) OVER (PARTITION BY customer_id) AS duplicate_count
FROM heyrcg_stg.stg_customers
WHERE is_snapshot_row AND quarantine_reason IS NULL
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY customer_id
  ORDER BY
    email IS NULL,
    (CASE WHEN full_name IS NULL THEN 0 ELSE 1 END + CASE WHEN email IS NULL THEN 0 ELSE 1 END
     + CASE WHEN phone IS NULL THEN 0 ELSE 1 END + CASE WHEN city IS NULL THEN 0 ELSE 1 END
     + CASE WHEN nationality IS NULL THEN 0 ELSE 1 END + CASE WHEN joined_date IS NULL THEN 0 ELSE 1 END
     + CASE WHEN loyalty_tier IS NULL THEN 0 ELSE 1 END) DESC,
    email NULLS FIRST,
    row_hash
) = 1;

-- stg_bookings --------------------------------------------------------------------------
CREATE OR REPLACE VIEW heyrcg_stg.stg_bookings AS
WITH typed AS (
  SELECT
    _source_file AS source_file,
    _source_row  AS source_row,
    _loaded_at   AS loaded_at,
    NULLIF(UPPER(TRIM(BookingID)), '') AS booking_id,
    TRIM(hotel_name) AS hotel_name,
    NULLIF(TRIM(RoomType), '') AS room_type,
    NULLIF(UPPER(TRIM(customer_id)), '') AS customer_id,
    try_strptime(TRIM(CheckInDate), '%Y-%m-%d')::DATE    AS check_in_raw,
    try_strptime(TRIM(check_out_date), '%Y-%m-%d')::DATE AS check_out_raw,
    TRY_CAST(TRIM(nights) AS BIGINT) AS nights,
    LOWER(TRIM(booking_status)) AS status_key,
    TRIM(booking_status) AS booking_status_raw,
    NULLIF(TRIM(channel), '') AS channel,
    NULLIF(TRIM(BookingSource), '') AS booking_source,
    TRY_CAST(NULLIF(TRIM(RatePerNight), '') AS DECIMAL(38, 9)) AS rate_per_night,
    UPPER(TRIM(Currency)) AS currency,
    TRY_CAST(NULLIF(TRIM(TotalRevenue_IDR), '') AS DECIMAL(38, 9)) AS total_revenue_idr_src,
    TRY_CAST(NULLIF(TRIM(discount_pct), '') AS DECIMAL(38, 9)) AS discount_pct,
    CASE LOWER(TRIM(is_loyalty_member))
      WHEN '1' THEN TRUE  WHEN 'true' THEN TRUE  WHEN 'yes' THEN TRUE
      WHEN '0' THEN FALSE WHEN 'false' THEN FALSE WHEN 'no' THEN FALSE
    END AS is_loyalty_member,
    try_strptime(TRIM(created_at), '%Y-%m-%d')::DATE AS booking_created_date,
    NULLIF(TRIM(updated_at), '') AS updated_at_raw,
    try_strptime(TRIM(updated_at), '%Y-%m-%d %H:%M:%S') AS updated_at
  FROM heyrcg_raw.bookings
),
enriched AS (
  SELECT
    t.*,
    s.booking_status,
    h.hotel_code,
    fx.idr_per_unit,
    CASE
      WHEN t.check_out_raw < t.check_in_raw
           AND date_diff('day', t.check_out_raw, t.check_in_raw) = t.nights THEN 'DATES_SWAPPED'
      WHEN t.check_out_raw < t.check_in_raw                                 THEN 'CHECKOUT_RECOMPUTED'
    END AS date_fix
  FROM typed AS t
  LEFT JOIN heyrcg_stg.ref_booking_status AS s ON s.status_key = t.status_key
  LEFT JOIN heyrcg_stg.ref_hotel AS h ON h.hotel_name = t.hotel_name
  LEFT JOIN heyrcg_stg.ref_fx_rate AS fx ON fx.currency = t.currency
),
final AS (
  SELECT
    source_file, source_row, loaded_at, booking_id, hotel_code, hotel_name, room_type, customer_id,
    CASE WHEN date_fix = 'DATES_SWAPPED' THEN check_out_raw ELSE check_in_raw END AS check_in_date,
    CASE date_fix
      WHEN 'DATES_SWAPPED'       THEN check_in_raw
      WHEN 'CHECKOUT_RECOMPUTED' THEN check_in_raw + CAST(nights AS INTEGER)
      ELSE check_out_raw
    END AS check_out_date,
    nights, booking_status, booking_status_raw, channel, booking_source, rate_per_night, currency,
    discount_pct, is_loyalty_member, booking_created_date,
    COALESCE(total_revenue_idr_src, ROUND(rate_per_night * nights * idr_per_unit, 2)) AS room_revenue_idr,
    total_revenue_idr_src IS NULL AS is_revenue_derived,
    date_fix,
    updated_at_raw IS NULL AS is_snapshot_row,
    COALESCE(updated_at, :snapshot_ts) AS row_ts,
    CASE
      WHEN booking_id IS NULL                                  THEN 'MISSING_BOOKING_ID'
      WHEN check_in_raw IS NULL OR check_out_raw IS NULL       THEN 'INVALID_STAY_DATE'
      WHEN nights IS NULL OR nights <= 0                       THEN 'INVALID_NIGHTS'
      WHEN booking_status IS NULL                              THEN 'UNKNOWN_STATUS'
      WHEN hotel_code IS NULL                                  THEN 'UNKNOWN_HOTEL'
      WHEN idr_per_unit IS NULL                                THEN 'UNKNOWN_CURRENCY'
      WHEN total_revenue_idr_src IS NULL AND rate_per_night IS NULL THEN 'NO_REVENUE_SOURCE'
      WHEN booking_created_date IS NULL                        THEN 'INVALID_CREATED_AT'
      WHEN updated_at_raw IS NOT NULL AND updated_at IS NULL   THEN 'INVALID_UPDATED_AT'
    END AS quarantine_reason
  FROM enriched
)
SELECT
  *,
  CASE WHEN booking_status IN ('CANCELLED', 'NO_SHOW') THEN 0 ELSE room_revenue_idr END AS recognised_room_revenue_idr,
  sha256(to_json(struct_pack(
    hotel_code := hotel_code, room_type := room_type, customer_id := customer_id,
    check_in_date := check_in_date, check_out_date := check_out_date, nights := nights,
    booking_status := booking_status, channel := channel, booking_source := booking_source,
    rate_per_night := rate_per_night, currency := currency, discount_pct := discount_pct,
    is_loyalty_member := is_loyalty_member, booking_created_date := booking_created_date,
    room_revenue_idr := room_revenue_idr, is_revenue_derived := is_revenue_derived, date_fix := date_fix
  ))::VARCHAR) AS row_hash
FROM final;

-- stg_pos_transactions ------------------------------------------------------------------
CREATE OR REPLACE VIEW heyrcg_stg.stg_pos_transactions AS
WITH typed AS (
  SELECT
    _source_file AS source_file,
    _source_row  AS source_row,
    _loaded_at   AS loaded_at,
    NULLIF(UPPER(TRIM(pos_transaction_id)), '') AS pos_line_id,
    TRIM(outlet_name) AS outlet_name,
    NULLIF(TRIM(hotel_name), '') AS hotel_name_src,
    TRIM(transaction_date) AS transaction_date_raw,
    NULLIF(UPPER(TRIM(customer_id)), '') AS customer_id,
    TRIM(item_name) AS item_name_raw,
    LOWER(regexp_replace(item_name, '[^A-Za-z0-9]', '', 'g')) AS item_key,
    NULLIF(initcap1(TRIM(category)), '') AS category_src,
    TRY_CAST(TRIM(quantity) AS BIGINT) AS quantity,
    TRY_CAST(NULLIF(TRIM(unit_price), '') AS DECIMAL(38, 9)) AS unit_price_src,
    TRY_CAST(NULLIF(regexp_replace(UPPER(total_amount), 'IDR|,|\s', '', 'g'), '') AS DECIMAL(38, 9)) AS total_amount_idr,
    TRIM(total_amount) AS total_amount_raw,
    LOWER(regexp_replace(payment_method, '[^A-Za-z0-9]', '', 'g')) AS payment_key,
    NULLIF(TRIM(staff_id), '') AS staff_id
  FROM heyrcg_raw.pos_transactions
),
parsed AS (
  SELECT
    t.*,
    CASE
      WHEN regexp_matches(transaction_date_raw, '^\d{4}-\d{2}-\d{2}$') THEN try_strptime(transaction_date_raw, '%Y-%m-%d')::DATE
      WHEN regexp_matches(transaction_date_raw, '^\d{8}$')             THEN try_strptime(transaction_date_raw, '%Y%m%d')::DATE
      WHEN regexp_matches(transaction_date_raw, '^\d{2}-\d{2}-\d{4}$') THEN try_strptime(transaction_date_raw, '%m-%d-%Y')::DATE
      WHEN regexp_matches(transaction_date_raw, '^\d{2}/\d{2}/\d{4}$') THEN try_strptime(transaction_date_raw, '%d/%m/%Y')::DATE
      WHEN regexp_matches(transaction_date_raw, '^\d{1,2} [A-Za-z]{3} \d{4}$') THEN try_strptime(transaction_date_raw, '%d %b %Y')::DATE
    END AS transaction_date,
    COALESCE(t.hotel_name_src, oh.hotel_name) AS hotel_name,
    it.item_name,
    it.category AS item_category,
    pm.payment_method,
    pm.payment_type
  FROM typed AS t
  LEFT JOIN heyrcg_stg.ref_outlet_hotel AS oh ON oh.outlet_name = t.outlet_name
  LEFT JOIN heyrcg_stg.ref_pos_item AS it ON it.item_key = t.item_key
  LEFT JOIN heyrcg_stg.ref_payment_method AS pm ON pm.payment_key = t.payment_key
),
final AS (
  SELECT
    p.source_file, p.source_row, p.loaded_at, p.pos_line_id, p.outlet_name, h.hotel_code, p.hotel_name,
    p.hotel_name_src IS NULL AS is_hotel_inferred,
    p.transaction_date, p.transaction_date_raw, p.customer_id, p.item_name, p.item_name_raw,
    COALESCE(p.category_src, p.item_category) AS category,
    p.category_src IS NULL AS is_category_inferred,
    p.quantity,
    CAST(COALESCE(p.unit_price_src, p.total_amount_idr / NULLIF(p.quantity, 0)) AS DECIMAL(38, 9)) AS unit_price_idr,
    p.unit_price_src IS NULL AS is_unit_price_derived,
    p.total_amount_idr, p.total_amount_raw, p.payment_method, p.payment_type, p.staff_id,
    p.unit_price_src IS NOT NULL AND p.total_amount_idr != p.unit_price_src * p.quantity AS is_amount_mismatch,
    CASE
      WHEN p.pos_line_id IS NULL                       THEN 'MISSING_POS_ID'
      WHEN p.transaction_date IS NULL                  THEN 'INVALID_TRANSACTION_DATE'
      WHEN p.total_amount_idr IS NULL                  THEN 'INVALID_TOTAL_AMOUNT'
      WHEN p.quantity IS NULL OR p.quantity <= 0       THEN 'INVALID_QUANTITY'
      WHEN p.item_name IS NULL                         THEN 'UNKNOWN_ITEM'
      WHEN h.hotel_code IS NULL                        THEN 'UNKNOWN_HOTEL'
      WHEN p.payment_method IS NULL                    THEN 'UNKNOWN_PAYMENT_METHOD'
      WHEN p.category_src IS NOT NULL AND p.category_src != p.item_category THEN 'CATEGORY_CONFLICT'
    END AS quarantine_reason
  FROM parsed AS p
  LEFT JOIN heyrcg_stg.ref_hotel AS h ON h.hotel_name = p.hotel_name
)
SELECT
  *,
  ROW_NUMBER() OVER (PARTITION BY pos_line_id ORDER BY source_file, source_row) AS duplicate_rank,
  sha256(to_json(struct_pack(
    outlet_name := outlet_name, hotel_code := hotel_code, transaction_date := transaction_date,
    customer_id := customer_id, item_name := item_name, category := category, quantity := quantity,
    unit_price_idr := unit_price_idr, total_amount_idr := total_amount_idr,
    payment_method := payment_method, staff_id := staff_id
  ))::VARCHAR) AS row_hash
FROM final;

-- stg_quarantine ------------------------------------------------------------------------
CREATE OR REPLACE VIEW heyrcg_stg.stg_quarantine AS
SELECT 'customers' AS source_name, 'QUARANTINED' AS action, quarantine_reason AS reason,
       source_file, source_row, customer_id AS business_key
FROM heyrcg_stg.stg_customers WHERE quarantine_reason IS NOT NULL
UNION ALL
SELECT 'customers', 'DUPLICATE_REMOVED', 'SAME_CUSTOMER_ID_IN_INITIAL_DUMP', c.source_file, c.source_row, c.customer_id
FROM heyrcg_stg.stg_customers AS c
WHERE c.is_snapshot_row AND c.quarantine_reason IS NULL
  AND NOT EXISTS (SELECT 1 FROM heyrcg_stg.stg_customers_snapshot AS s
                  WHERE s.source_file = c.source_file AND s.source_row = c.source_row)
UNION ALL
SELECT 'bookings', 'QUARANTINED', quarantine_reason, source_file, source_row, booking_id
FROM heyrcg_stg.stg_bookings WHERE quarantine_reason IS NOT NULL
UNION ALL
SELECT 'pos_transactions', 'QUARANTINED', quarantine_reason, source_file, source_row, pos_line_id
FROM heyrcg_stg.stg_pos_transactions WHERE quarantine_reason IS NOT NULL
UNION ALL
SELECT 'pos_transactions', 'DUPLICATE_REMOVED', 'EXACT_COPY_OF_EARLIER_ROW', source_file, source_row, pos_line_id
FROM heyrcg_stg.stg_pos_transactions WHERE duplicate_rank > 1
UNION ALL
SELECT 'customers', 'FLAGGED', 'EMAIL_INVALID_SET_TO_NULL', source_file, source_row, customer_id
FROM heyrcg_stg.stg_customers WHERE is_email_invalid AND quarantine_reason IS NULL
UNION ALL
SELECT 'bookings', 'FLAGGED', date_fix, source_file, source_row, booking_id
FROM heyrcg_stg.stg_bookings WHERE date_fix IS NOT NULL AND quarantine_reason IS NULL
UNION ALL
SELECT 'bookings', 'FLAGGED', 'REVENUE_DERIVED_FROM_RATE', source_file, source_row, booking_id
FROM heyrcg_stg.stg_bookings WHERE is_revenue_derived AND quarantine_reason IS NULL
UNION ALL
SELECT 'pos_transactions', 'FLAGGED', 'HOTEL_FILLED_FROM_OUTLET', source_file, source_row, pos_line_id
FROM heyrcg_stg.stg_pos_transactions WHERE is_hotel_inferred AND quarantine_reason IS NULL AND duplicate_rank = 1
UNION ALL
SELECT 'pos_transactions', 'FLAGGED', 'CATEGORY_FILLED_FROM_ITEM', source_file, source_row, pos_line_id
FROM heyrcg_stg.stg_pos_transactions WHERE is_category_inferred AND quarantine_reason IS NULL AND duplicate_rank = 1
UNION ALL
SELECT 'pos_transactions', 'FLAGGED', 'UNIT_PRICE_DERIVED_FROM_TOTAL', source_file, source_row, pos_line_id
FROM heyrcg_stg.stg_pos_transactions WHERE is_unit_price_derived AND quarantine_reason IS NULL AND duplicate_rank = 1;
