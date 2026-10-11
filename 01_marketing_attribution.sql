-- ============================================================
-- Marketing Attribution Mart
-- Layer  : mart
-- Refresh: daily, full-scan on 90-day rolling window
-- ============================================================
--
-- PURPOSE
-- Assigns first-touch and last-touch acquisition credit to
-- marketing channels, then joins to purchase revenue so the
-- business can calculate CAC and ROAS by channel.
--
-- ATTRIBUTION WINDOWS
--   First-touch : the very first session ever recorded for a user
--   Last-touch  : the most recent session within 30 days BEFORE
--                 the user's first purchase (last-click logic)
--
-- CHANNEL CLASSIFICATION PRIORITY (applied in the CASE statement)
--   1. Paid search      — utm_medium IN ('cpc','ppc','paid_search')
--   2. Paid social      — utm_medium IN ('paid_social','social_paid')
--   3. Email            — utm_medium = 'email'
--   4. Organic search   — referrer domain is a known search engine
--   5. Referral         — referrer present but not a search engine
--   6. Direct / none    — no referrer, no utm parameters
-- ============================================================

WITH

-- ─── raw_sessions ──────────────────────────────────────────
-- Simulates the staging-layer sessions table.
-- In production this is `staging.sessions`, a deduplicated view
-- over the raw event stream with typed columns.
raw_sessions AS (
    SELECT
        session_id,
        user_id,
        session_started_at,
        utm_source,
        utm_medium,
        utm_campaign,
        referrer_url,
        -- Normalise referrer domain for channel matching
        NET.HOST(referrer_url) AS referrer_domain
    FROM
        `synthetic_project.staging.sessions`
    WHERE
        -- Limit to a 90-day lookback to keep the scan affordable
        session_started_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
),

-- ─── classified_sessions ────────────────────────────────────
-- Applies the channel taxonomy to every session.
-- All classification logic lives here so it can be updated in
-- one place without touching downstream CTEs.
classified_sessions AS (
    SELECT
        session_id,
        user_id,
        session_started_at,
        utm_source,
        utm_medium,
        utm_campaign,
        referrer_url,
        referrer_domain,
        CASE
            -- Paid search: any CPC/PPC medium
            WHEN LOWER(utm_medium) IN ('cpc', 'ppc', 'paid_search', 'paidsearch')
                THEN 'paid_search'
            -- Paid social: explicitly tagged social spend
            WHEN LOWER(utm_medium) IN ('paid_social', 'social_paid', 'social_cpc')
                THEN 'paid_social'
            -- Email: newsletter or CRM campaigns
            WHEN LOWER(utm_medium) IN ('email', 'newsletter', 'crm')
                THEN 'email'
            -- Organic search: major search engine referrers without paid medium
            WHEN referrer_domain IN (
                'google.com', 'www.google.com',
                'bing.com', 'www.bing.com',
                'duckduckgo.com', 'search.yahoo.com'
            ) AND (utm_medium IS NULL OR LOWER(utm_medium) = 'organic')
                THEN 'organic_search'
            -- Referral: a non-search-engine external referrer
            WHEN referrer_domain IS NOT NULL
             AND referrer_domain NOT IN (
                'google.com', 'www.google.com',
                'bing.com', 'www.bing.com',
                'duckduckgo.com', 'search.yahoo.com'
             )
                THEN 'referral'
            -- Social organic (medium tagged but no spend tracking)
            WHEN LOWER(utm_medium) IN ('social', 'social_organic')
                THEN 'social_organic'
            -- Direct: no referrer and no utm parameters
            ELSE 'direct'
        END AS channel
    FROM
        raw_sessions
),

-- ─── first_touch ────────────────────────────────────────────
-- One row per user: the channel of their very first session.
-- QUALIFY with ROW_NUMBER ensures we pick exactly one row even
-- if two sessions share the same timestamp (rare but possible
-- in high-concurrency environments).
first_touch AS (
    SELECT
        user_id,
        channel         AS first_touch_channel,
        utm_campaign    AS first_touch_campaign,
        session_started_at AS first_session_at
    FROM (
        SELECT
            user_id,
            channel,
            utm_campaign,
            session_started_at,
            ROW_NUMBER() OVER (
                PARTITION BY user_id
                ORDER BY session_started_at ASC
            ) AS rn
        FROM classified_sessions
    )
    WHERE rn = 1
),

-- ─── purchases ──────────────────────────────────────────────
-- First purchase per user from the staging purchases table.
-- We only care about the first purchase for attribution
-- (repeat purchases are tracked separately in the LTV mart).
user_first_purchases AS (
    SELECT
        user_id,
        MIN(purchased_at)   AS first_purchase_at,
        SUM(revenue_usd)    AS total_revenue_usd   -- lifetime, for context
    FROM
        `synthetic_project.staging.purchases`
    GROUP BY
        user_id
),

-- ─── last_touch ─────────────────────────────────────────────
-- For users who made a purchase, find the last session within
-- a 30-day window BEFORE the purchase timestamp.
-- This is the standard "last-click" attribution model.
last_touch AS (
    SELECT
        cs.user_id,
        cs.channel       AS last_touch_channel,
        cs.utm_campaign  AS last_touch_campaign
    FROM classified_sessions cs
    INNER JOIN user_first_purchases p
        ON cs.user_id = p.user_id
       -- Session must be within the 30-day attribution window before purchase
       AND cs.session_started_at <= p.first_purchase_at
       AND cs.session_started_at >= TIMESTAMP_SUB(p.first_purchase_at, INTERVAL 30 DAY)
    QUALIFY
        ROW_NUMBER() OVER (
            PARTITION BY cs.user_id
            ORDER BY cs.session_started_at DESC  -- latest session wins
        ) = 1
),

-- ─── user_attribution ───────────────────────────────────────
-- Join first-touch and last-touch into a single user-level row.
-- Users who never purchased will have NULL last-touch columns.
user_attribution AS (
    SELECT
        ft.user_id,
        ft.first_touch_channel,
        ft.first_touch_campaign,
        ft.first_session_at,
        lt.last_touch_channel,
        lt.last_touch_campaign,
        p.first_purchase_at,
        p.total_revenue_usd,
        -- Days to first purchase (NULL if no purchase)
        DATE_DIFF(
            DATE(p.first_purchase_at),
            DATE(ft.first_session_at),
            DAY
        ) AS days_to_first_purchase
    FROM
        first_touch ft
    LEFT JOIN last_touch lt
        USING (user_id)
    LEFT JOIN user_first_purchases p
        USING (user_id)
)

-- ─── Final output ────────────────────────────────────────────
-- Channel-level summary: unique users and revenue attributed
-- under both models, enabling side-by-side CAC comparison.
SELECT
    -- Attribution dimensions
    first_touch_channel,
    last_touch_channel,
    -- Volume metrics
    COUNT(DISTINCT user_id)                                     AS total_users,
    COUNTIF(first_purchase_at IS NOT NULL)                      AS converting_users,
    SAFE_DIVIDE(
        COUNTIF(first_purchase_at IS NOT NULL),
        COUNT(DISTINCT user_id)
    )                                                           AS conversion_rate,
    -- Revenue metrics
    SUM(total_revenue_usd)                                      AS total_revenue_usd,
    AVG(total_revenue_usd)                                      AS avg_revenue_per_converting_user,
    -- Time to convert
    AVG(days_to_first_purchase)                                 AS avg_days_to_first_purchase,
    APPROX_QUANTILES(days_to_first_purchase, 100)[OFFSET(50)]  AS median_days_to_first_purchase
FROM
    user_attribution
GROUP BY
    first_touch_channel,
    last_touch_channel
ORDER BY
    total_revenue_usd DESC
