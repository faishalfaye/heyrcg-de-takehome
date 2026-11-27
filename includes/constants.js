// Shared constants for every SQLX file. Use them as ${constants.RAW} etc.
const vars = dataform.projectConfig.vars;

module.exports = {
  RAW: vars.raw_dataset,                       // dataset loaded by scripts/load_raw.py
  STG: "heyrcg_stg",
  MART: "heyrcg_mart",
  AUDIT: "heyrcg_audit",
  SNAPSHOT_TS: `DATETIME '${vars.snapshot_ts}'`,     // initial extraction time = first watermark
  BACKFILL_FROM: vars.backfill_from ? `DATETIME '${vars.backfill_from}'` : null,
  LOW_DT: "DATETIME '1900-01-01 00:00:00'",          // start of the first version of every customer
  HIGH_DT: "DATETIME '9999-12-31 23:59:59'",         // valid_to of the current version
  EMAIL_RE: "r'^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$'",
  NON_REVENUE_STATUSES: "('CANCELLED', 'NO_SHOW')", // ASSUMPTION K5: no room revenue recognised
};
