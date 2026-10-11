-- ============================================================
-- User Cohort LTV Mart
-- Layer  : mart
-- Refresh: weekly (runs every Monday 04:00 UTC)
-- ============================================================
--
-- PURPOSE
-- Segments users by registration week (weekly cohorts) and
-- tracks cumulative revenue and retention across four standard
-- observation windows. Used to:
--   - Monitor payback period trends cohort-over-cohort
--   - Identify whether LTV improvement comes from better
--     early conversion or better long-term retention
--   - Power the LTV curve visualisation in the BI layer
--
-- COHORT DEFINITION
--   A cohort is the ISO week in which the user registered.
--   DATE_TRUNC(registered_at, WEEK(MONDAY)) ensures Monday-based
--   weeks consistent with the BI tool's calendar settings.
--
-- OBSERVATION WINDOWS
--   ltv_7d  : revenue earned in days 0–7 after registration
--   ltv_30d : revenue earned in days 0–30
--   ltv_90d : revenue earned in days 0–90
--
-- RETENTION DEFINITIONS
--   D1  : user had at least 1 session on day 1 after registration
--   D3  : ... on day 3 (±0 tolerance)
--   D7  : ... on day 7 (within days 6–8 to absorb timezone drift)
--   D14 : ... within days 13–15
--   D30 : ... within days 29–31
-- ============================================================

WITH

-- ─── cohort_base ────────────────────────────────────────────
-- One row per user with their cohort week label.
-- We filter out users registered in the current incomplete
-- week so metrics are not diluted by partial data.
cohort_base AS (
    SELECT
        user_id,
        registered_at,
        DATE_TRUNC(DATE(registered_at), WEEK(MONDAY)) AS cohort_week,
        country_code,
        acquisition_channel   -- carried through for optional segmentation
    FROM
        `synthetic_project.staging.users`
    WHERE
        -- Exclude the current incomplete week
        DATE_TRUNC(DATE(registered_at), WEEK(MONDAY))
            < DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
        -- Only look back 6 months to keep query cost bounded;
        -- historical cohorts beyond this window are in a separate
        -- partitioned archive table
        AND registered_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 180 DAY)
),

-- ─── cohort_size ────────────────────────────────────────────
-- Pre-aggregate cohort sizes so we don't repeat the COUNT
-- in every downstream join.
cohort_size AS (
    SELECT
        cohort_week,
        COUNT(DISTINCT user_id) AS cohort_size
    FROM
        cohort_base
    GROUP BY
        cohort_week
),

-- ─── cohort_activity ────────────────────────────────────────
-- Join each user's sessions to their registration timestamp
-- and compute the day offset. This is the foundation for
-- both retention and revenue window calculations.
cohort_activity AS (
    SELECT
        cb.user_id,
        cb.cohort_week,
        cb.registered_at,
        s.session_started_at,
        -- Integer day offset from registration (floor division)
        DATE_DIFF(
            DATE(s.session_started_at),
            DATE(cb.registered_at),
            DAY
        ) AS day_offset
    FROM
        cohort_base cb
    INNER JOIN `synthetic_project.staging.sessions` s
        USING (user_id)
    WHERE
        -- Only include sessions that fall within 90 days of registration
        s.session_started_at >= cb.registered_at
        AND s.session_started_at
            < TIMESTAMP_ADD(cb.registered_at, INTERVAL 90 DAY)
),

-- ─── cohort_revenue ─────────────────────────────────────────
-- Aggregate revenue per user across the three standard LTV
-- windows. We use conditional aggregation (SUM + IF) rather
-- than pivoting to keep the query readable and to make it
-- easy to add new windows later.
cohort_revenue AS (
    SELECT
        cb.user_id,
        cb.cohort_week,
        -- Window 1: days 0–7 (immediate monetisation)
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 0 AND 7,
            p.revenue_usd, 0
        )) AS revenue_0_7d,
        -- Window 2: days 0–30 (short-term LTV)
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 0 AND 30,
            p.revenue_usd, 0
        )) AS revenue_0_30d,
        -- Window 3: days 0–90 (medium-term LTV)
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 0 AND 90,
            p.revenue_usd, 0
        )) AS revenue_0_90d
    FROM
        cohort_base cb
    LEFT JOIN `synthetic_project.staging.purchases` p
        ON cb.user_id = p.user_id
       AND p.purchased_at >= cb.registered_at
       AND p.purchased_at < TIMESTAMP_ADD(cb.registered_at, INTERVAL 91 DAY)
    GROUP BY
        cb.user_id,
        cb.cohort_week
),

-- ─── cohort_revenue_agg ─────────────────────────────────────
-- Roll up per-user revenue to cohort-week level.
-- We compute both the total (sum) and the per-user average (avg)
-- because the BI layer needs both for different chart types.
cohort_revenue_agg AS (
    SELECT
        cohort_week,
        AVG(revenue_0_7d)   AS avg_ltv_7d,
        AVG(revenue_0_30d)  AS avg_ltv_30d,
        AVG(revenue_0_90d)  AS avg_ltv_90d,
        SUM(revenue_0_7d)   AS total_revenue_7d,
        SUM(revenue_0_30d)  AS total_revenue_30d,
        SUM(revenue_0_90d)  AS total_revenue_90d
    FROM
        cohort_revenue
    GROUP BY
        cohort_week
),

-- ─── cohort_retention ───────────────────────────────────────
-- For each cohort, calculate the fraction of users who had
-- at least one session on each milestone day.
-- Day-7 tolerance (±1 day) absorbs timezone discrepancies
-- for users near UTC boundaries.
cohort_retention AS (
    SELECT
        cohort_week,
        -- D1: returned on calendar day 1 after registration
        SAFE_DIVIDE(
            COUNT(DISTINCT IF(day_offset = 1, user_id, NULL)),
            COUNT(DISTINCT user_id)
        ) AS d1_retention,
        -- D3: returned on calendar day 3
        SAFE_DIVIDE(
            COUNT(DISTINCT IF(day_offset = 3, user_id, NULL)),
            COUNT(DISTINCT user_id)
        ) AS d3_retention,
        -- D7: returned in a ±1 day window around day 7
        SAFE_DIVIDE(
            COUNT(DISTINCT IF(day_offset BETWEEN 6 AND 8, user_id, NULL)),
            COUNT(DISTINCT user_id)
        ) AS d7_retention,
        -- D14: returned in a ±1 day window around day 14
        SAFE_DIVIDE(
            COUNT(DISTINCT IF(day_offset BETWEEN 13 AND 15, user_id, NULL)),
            COUNT(DISTINCT user_id)
        ) AS d14_retention,
        -- D30: returned in a ±1 day window around day 30
        SAFE_DIVIDE(
            COUNT(DISTINCT IF(day_offset BETWEEN 29 AND 31, user_id, NULL)),
            COUNT(DISTINCT user_id)
        ) AS d30_retention
    FROM
        cohort_activity
    GROUP BY
        cohort_week
),

-- ─── revenue_buckets ────────────────────────────────────────
-- Additional breakdown: what share of each cohort's 90-day
-- revenue was earned in each time bucket?
-- Useful for understanding whether the LTV curve is front-loaded
-- (sign of high early monetisation) or long-tail (subscription-like).
revenue_buckets AS (
    SELECT
        cb.cohort_week,
        -- Bucket 1: first week
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 0 AND 7,
            p.revenue_usd, 0
        )) AS bucket_0_7d,
        -- Bucket 2: week 2 to end of month 1
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 8 AND 30,
            p.revenue_usd, 0
        )) AS bucket_8_30d,
        -- Bucket 3: month 2
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 31 AND 60,
            p.revenue_usd, 0
        )) AS bucket_31_60d,
        -- Bucket 4: month 3
        SUM(IF(
            DATE_DIFF(DATE(p.purchased_at), DATE(cb.registered_at), DAY) BETWEEN 61 AND 90,
            p.revenue_usd, 0
        )) AS bucket_61_90d
    FROM
        cohort_base cb
    LEFT JOIN `synthetic_project.staging.purchases` p
        ON cb.user_id = p.user_id
       AND p.purchased_at >= cb.registered_at
       AND p.purchased_at < TIMESTAMP_ADD(cb.registered_at, INTERVAL 91 DAY)
    GROUP BY
        cb.cohort_week
)

-- ─── Final output ────────────────────────────────────────────
-- One row per cohort week, combining size, retention, LTV,
-- and revenue bucket breakdown. Sorted newest-first so the BI
-- tool's default view shows the most recent cohorts at the top.
SELECT
    -- Cohort identity
    cs.cohort_week,
    cs.cohort_size,

    -- Retention rates (rounded to 4 dp for display)
    ROUND(cr.d1_retention,  4) AS d1_retention,
    ROUND(cr.d3_retention,  4) AS d3_retention,
    ROUND(cr.d7_retention,  4) AS d7_retention,
    ROUND(cr.d14_retention, 4) AS d14_retention,
    ROUND(cr.d30_retention, 4) AS d30_retention,

    -- Average LTV per user (key KPI for cohort health)
    ROUND(ra.avg_ltv_7d,  2) AS avg_ltv_7d,
    ROUND(ra.avg_ltv_30d, 2) AS avg_ltv_30d,
    ROUND(ra.avg_ltv_90d, 2) AS avg_ltv_90d,

    -- Total cohort revenue (used for absolute payback calculations)
    ROUND(ra.total_revenue_7d,  2) AS total_revenue_7d,
    ROUND(ra.total_revenue_30d, 2) AS total_revenue_30d,
    ROUND(ra.total_revenue_90d, 2) AS total_revenue_90d,

    -- Revenue bucket breakdown (useful for LTV curve shape analysis)
    ROUND(rb.bucket_0_7d,   2) AS revenue_bucket_0_7d,
    ROUND(rb.bucket_8_30d,  2) AS revenue_bucket_8_30d,
    ROUND(rb.bucket_31_60d, 2) AS revenue_bucket_31_60d,
    ROUND(rb.bucket_61_90d, 2) AS revenue_bucket_61_90d,

    -- Share of 90-day revenue earned in the first 7 days
    -- High value (>50%) indicates a front-loaded monetisation model
    ROUND(SAFE_DIVIDE(rb.bucket_0_7d, ra.total_revenue_90d), 4)
        AS pct_revenue_in_first_week

FROM
    cohort_size cs
LEFT JOIN cohort_retention cr
    USING (cohort_week)
LEFT JOIN cohort_revenue_agg ra
    USING (cohort_week)
LEFT JOIN revenue_buckets rb
    USING (cohort_week)
ORDER BY
    cohort_week DESC
