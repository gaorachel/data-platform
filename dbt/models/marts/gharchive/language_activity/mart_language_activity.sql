{{
    config(
        materialized='incremental',
        unique_key=["event_date", "language", "contributor_type"],
        incremental_strategy='delete+insert'
    )
}}

WITH events AS (

    SELECT
        event_date,
        COALESCE(language, 'unknown') AS language,
        contributor_type,
        actor_login,
        repo_name
    FROM {{ ref('int_gharchive__events_enriched') }}
    WHERE 1=1
        AND event_date <= DATEADD(day, -1, CURRENT_DATE) -- exclude today's incomplete data
        {% if is_incremental() %}
        AND event_date >= DATEADD(day, -3, CURRENT_DATE)
        {% endif %}

)

SELECT
    event_date,
    language,
    contributor_type,
    COUNT(*)                    AS event_count,
    COUNT(DISTINCT actor_login) AS unique_contributors,
    COUNT(DISTINCT repo_name)   AS unique_repos,
    CURRENT_TIMESTAMP           AS _sdc_batched_at
FROM events
WHERE 1=1
    AND language != 'unknown' -- filter out events with unknown language to focus on meaningful trends
GROUP BY 
    event_date, 
    language, 
    contributor_type
