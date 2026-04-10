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
    {% if is_incremental() %}
    WHERE event_date >= DATEADD(day, -3, CURRENT_DATE)
    {% endif %}

)

SELECT
    event_date,
    language,
    contributor_type,
    COUNT(*)                   AS event_count,
    COUNT(DISTINCT actor_login) AS unique_contributors,
    COUNT(DISTINCT repo_name)  AS unique_repos

FROM events
WHERE event_date <= DATEADD(day, -1, CURRENT_DATE) -- ensure we only include complete days in the results

GROUP BY event_date, language, contributor_type
