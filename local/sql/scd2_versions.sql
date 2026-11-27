-- Port of includes/scd2.js. Inserted by run_local.py as CTEs; {customer_filter} is replaced.
log AS (
  SELECT * FROM heyrcg_audit.customer_change_log
  WHERE {customer_filter}
  QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id, row_ts ORDER BY row_hash) = 1
),
ordered AS (
  SELECT *, ROW_NUMBER() OVER w AS rn, LAG(loyalty_tier) OVER w AS previous_tier
  FROM log
  WINDOW w AS (PARTITION BY customer_id ORDER BY row_ts)
),
version_starts AS (
  SELECT customer_id, loyalty_tier,
         CASE WHEN rn = 1 THEN TIMESTAMP '1900-01-01 00:00:00' ELSE row_ts END AS valid_from
  FROM ordered
  WHERE rn = 1 OR loyalty_tier IS DISTINCT FROM previous_tier
),
newest AS (
  SELECT * FROM log
  QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY row_ts DESC) = 1
),
versions AS (
  SELECT
    v.customer_id, n.full_name, n.email, n.phone, n.city, n.nationality, n.joined_date,
    v.loyalty_tier, v.valid_from,
    COALESCE(LEAD(v.valid_from) OVER (PARTITION BY v.customer_id ORDER BY v.valid_from),
             TIMESTAMP '9999-12-31 23:59:59') AS valid_to,
    n.row_ts AS source_updated_at
  FROM version_starts AS v
  JOIN newest AS n USING (customer_id)
),
customer_versions AS (
  SELECT
    farm_fingerprint(customer_id || '|' || strftime(valid_from, '%Y-%m-%d %H:%M:%S')) AS customer_key,
    customer_id, full_name, email, phone, city, nationality, joined_date, loyalty_tier,
    valid_from, valid_to,
    valid_to = TIMESTAMP '9999-12-31 23:59:59' AS is_current,
    FALSE AS is_inferred,
    source_updated_at
  FROM versions
)
