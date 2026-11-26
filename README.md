# HeyRCG take-home: incremental Kimball mart on BigQuery + Dataform

Raw bookings, customers and POS data are cleaned, modelled into a star schema, and kept up to date
from daily delta files without rebuilding (watermark + MERGE + SCD Type 2, in one transaction).

## Architecture

```mermaid
flowchart TD
    A[CSV initial<br/>data/] --> L[scripts/load_raw.sh<br/>all STRING + file manifest]
    B[CSV delta<br/>2024-04-01] --> L
    L --> R[(heyrcg_raw)]
    R --> I[Dataform tag: initial<br/>staging + first build]
    R --> N[Dataform tag: incremental<br/>one transaction, MERGE]
    I --> M[(heyrcg_mart + heyrcg_audit<br/>dims, facts, watermark)]
    N --> M
    M --> T[Assertions<br/>expected outcomes, recompute]
    M --> P[Reports<br/>revenue by hotel, F&B per guest]
```

| Layer | Dataset | Contents |
|---|---|---|
| Raw | `heyrcg_raw` | CSV rows as received + `file_manifest` |
| Staging | `heyrcg_stg` | `stg_*` cleaned views, `ref_*` mapping tables, `stg_quarantine` |
| Mart | `heyrcg_mart` | `dim_date`, `dim_hotel`, `dim_customer` (SCD2), `fact_bookings`, `fact_pos_transactions`, `rpt_*` |
| Audit | `heyrcg_audit` | `etl_watermark`, `customer_change_log`, `etl_run_log` |
