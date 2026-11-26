// SCD2 version builder for dim_customer. Used by BOTH the initial load and the
// incremental load, so there is exactly one definition of "what a version is".
//
// Usage: WITH ${scd2.customerVersionCtes(...)} SELECT * FROM customer_versions
//
// Input: the customer change log = every accepted CRM row for a customer, with row_ts
// (when that row was true in the CRM). Output: the SCD2 versions of those customers.
//
// Rules (docs/decisions.md D5, D6):
//   1. Sort a customer's rows by row_ts.
//   2. A new version starts at the first row, and at every row whose loyalty_tier is
//      different from the previous row (NULL counts as a value, so NULL -> Bronze is a
//      change: ASSUMPTION K6). Rows that do not change the tier never create a version,
//      so "a row that changes nothing creates nothing" holds by construction.
//   3. The first version is valid from 1900-01-01, so every booking, however old, finds
//      a version. Later versions are valid from the row_ts of the row that changed the tier.
//   4. valid_to = valid_from of the next version (half-open interval [valid_from, valid_to)).
//   5. Type 1 attributes (name, email, phone, city, nationality, joined_date) are taken from
//      the NEWEST row and written on every version: Type 1 means "overwrite history".
//   6. customer_key = FARM_FINGERPRINT(customer_id | valid_from). Deterministic: rebuilding
//      the same history gives the same keys, so facts never point at a key that disappeared.
function customerVersionCtes(changeLog, customerFilter) {
  return `
  log AS (
    SELECT *
    FROM ${changeLog}
    WHERE ${customerFilter}
    -- two different rows with the exact same timestamp: keep one, deterministically
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id, row_ts ORDER BY row_hash) = 1
  ),
  ordered AS (
    SELECT
      *,
      ROW_NUMBER() OVER w AS rn,
      LAG(loyalty_tier) OVER w AS previous_tier
    FROM log
    WINDOW w AS (PARTITION BY customer_id ORDER BY row_ts)
  ),
  version_starts AS (
    SELECT
      customer_id,
      loyalty_tier,
      IF(rn = 1, ${constants.LOW_DT}, row_ts) AS valid_from
    FROM ordered
    WHERE rn = 1 OR loyalty_tier IS DISTINCT FROM previous_tier
  ),
  newest AS (
    SELECT *
    FROM log
    WHERE TRUE   -- BigQuery wants a WHERE next to QUALIFY
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY row_ts DESC) = 1
  ),
  versions AS (
      SELECT
        v.customer_id,
        n.full_name,
        n.email,
        n.phone,
        n.city,
        n.nationality,
        n.joined_date,
        v.loyalty_tier,
        v.valid_from,
        COALESCE(LEAD(v.valid_from) OVER (PARTITION BY v.customer_id ORDER BY v.valid_from), ${constants.HIGH_DT}) AS valid_to,
        n.row_ts AS source_updated_at
      FROM version_starts AS v
      JOIN newest AS n USING (customer_id)
  ),
  customer_versions AS (
  SELECT
    FARM_FINGERPRINT(CONCAT(customer_id, '|', FORMAT_DATETIME('%F %T', valid_from))) AS customer_key,
    customer_id, full_name, email, phone, city, nationality, joined_date, loyalty_tier,
    valid_from, valid_to,
    valid_to = ${constants.HIGH_DT} AS is_current,
    FALSE AS is_inferred,
    source_updated_at
  FROM versions
  )`;
}

// Hash of every business column of a dim_customer row. MERGE only touches a row when
// this changes, which keeps updated_at (and the table fingerprint) stable on a re-run.
const CUSTOMER_ROW_HASH = `TO_HEX(SHA256(TO_JSON_STRING(STRUCT(
  customer_id, full_name, email, phone, city, nationality, joined_date, loyalty_tier,
  valid_from, valid_to, is_current, is_inferred))))`;

module.exports = { customerVersionCtes, CUSTOMER_ROW_HASH };
