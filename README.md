# SQL Data Marts

## Architecture Overview

Both marts are built natively in **BigQuery** using **Dataform / SQLX** — Google's managed
dbt-equivalent. The transformation pipeline follows a standard multi-layer architecture:

```
raw (append-only source tables)
  └─► staging (typed, cleaned, deduplicated)
        └─► intermediate (business entity models)
              └─► mart (aggregated, BI-ready)
```

The SQL files in this folder represent the **mart layer** — the final, denormalised tables that
are queried by dashboards and downstream models. Each mart is a `SQLX` file that Dataform
compiles and schedules; the snippets here are shown as plain SQL for readability.

---

## Marts

### `01_marketing_attribution.sql` — Marketing Attribution Mart

Assigns user acquisition credit to marketing channels using both **first-touch** and
**last-touch** attribution models. Channel classification rules live in a single CTE, making
them easy to audit and update without touching downstream logic.

Output granularity: one row per user, with first-touch and last-touch channel labels, plus
revenue rolled up per channel for the final summary view.

Key business questions answered:
- Which acquisition channel drives the highest LTV users?
- What is the CAC by channel under first-touch vs last-touch attribution?
- Which campaigns are driving the most revenue in the 30-day payback window?

### `02_user_cohorts.sql` — User Cohort LTV Mart

Segments users by **registration week** (weekly cohorts via `DATE_TRUNC`) and tracks retention
and cumulative revenue across four observation windows: 0–7d, 8–30d, 31–60d, 61–90d.

Output granularity: one row per cohort week, with retention rates (D1, D7, D30) and cumulative
LTV at 7, 30, and 90 days.

Key business questions answered:
- How quickly do cohorts reach CAC payback?
- Are newer cohorts monetising better or worse than older ones?
- What is the typical LTV curve shape (fast early monetisation vs slow burn)?

---

## Notes on Production Versions

The queries shown here are simplified for readability. Production versions differ in the
following ways:

1. **Incremental updates** — marts run in `INSERT OR REPLACE` mode keyed on `cohort_week` /
   `user_id`, not full-table scans, to keep BigQuery slot costs manageable.
2. **Deduplication guards** — staging CTEs include `ROW_NUMBER() OVER (PARTITION BY event_id
   ORDER BY ingested_at DESC) = 1` filters to handle late-arriving or duplicate raw events.
3. **Data quality assertions** — Dataform `assertions` blocks check for nulls in key join
   columns and alert on unexpected row-count drops before the mart is promoted.
4. **Parameterised lookback** — the 30-day attribution lookback window is a Dataform variable,
   allowing the business to A/B test different attribution windows without SQL changes.
