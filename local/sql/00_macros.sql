-- DuckDB equivalents of the BigQuery functions the Dataform SQL uses.
-- Keys and hashes get different VALUES than in BigQuery (different hash functions),
-- but they are deterministic, which is all the pipeline relies on.
CREATE OR REPLACE MACRO farm_fingerprint(s) AS (hash(s)::HUGEINT - 9223372036854775808)::BIGINT;
-- BigQuery INITCAP for the single-word values we use it on (tiers, categories)
CREATE OR REPLACE MACRO initcap1(s) AS upper(s[1]) || lower(s[2:]);
-- BigQuery prints NUMERIC without trailing zeros; DuckDB DECIMAL keeps them
CREATE OR REPLACE MACRO num_str(x) AS
  CASE WHEN x = trunc(x) THEN CAST(CAST(x AS HUGEINT) AS VARCHAR)
       ELSE rtrim(rtrim(CAST(x AS VARCHAR), '0'), '.') END;
