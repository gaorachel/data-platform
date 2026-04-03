WITH events AS (

    SELECT *
    FROM {{ ref('int_gharchive__events_classified') }}

),

repo_metadata AS (

    SELECT
        repo_full_name,
        language,
        topics
    FROM {{ ref('stg_github__repo_metadata') }}

)

SELECT
    events.event_date,
    events.event_hour,
    events.event_id,
    events.event_type,
    events.created_at,
    events.actor_login,
    events.actor_type,
    events.repo_name,
    events.is_bot,
    events.contributor_type,
    repo_metadata.language,
    repo_metadata.topics

FROM events
LEFT JOIN repo_metadata
    ON events.repo_name = repo_metadata.repo_full_name
