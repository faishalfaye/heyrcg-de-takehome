# Evidence

Outputs of a real run of `scripts/run_all.sh` against BigQuery, committed so a reviewer can check
the claims in the main README without running anything.

| File | What it shows |
|---|---|
| `march_revenue_before_increment.txt` / `march_revenue_after_increment.txt` | `rpt_monthly_revenue_by_hotel` for 2024-03, before and after the delta |
| `fingerprint_before_increment.csv` | Mart state after the initial load |
| `fingerprint_after_run1.csv` / `fingerprint_after_run2.csv` | Must be identical: the second incremental run changed nothing |
| `idempotency_result.txt` | The diff verdict |
| `resend.txt` | Loading the same delta files again: skipped by the manifest |
| `run_log.txt` | `heyrcg_audit.etl_run_log`: watermark before/after and row counts per run |
| `quarantine_summary.txt` | Rows dropped, flagged and quarantined, per reason |
| `fingerprint_out_of_order.csv` (optional) | Out-of-order + backfill scenario; `fp_content` must equal run 1 |
