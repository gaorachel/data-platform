{{
    config(
        materialized='incremental',
        unique_key=["event_date", "contributor_type"],
        incremental_strategy='delete+insert'
    )
}}

WITH events AS (

    SELECT
        event_date,
        actor_login,
        contributor_type
    FROM {{ ref('int_gharchive__events_classified') }}
    WHERE 1=1
        AND event_date <= DATEADD(day, -1, CURRENT_DATE) -- exclude today's incomplete data
        {% if is_incremental() %}
        AND event_date >= DATEADD(day, -3, CURRENT_DATE)
        {% endif %}

)

SELECT
    event_date,
    contributor_type,
    COUNT(*)                    AS event_count,
    COUNT(DISTINCT actor_login) AS unique_contributors,
    CURRENT_TIMESTAMP           AS _sdc_batched_at
FROM events
GROUP BY 
    event_date, 
    contributor_type
