WITH source AS (

    SELECT
        event_date,
        event_hour,
        raw_event
    FROM {{ source('gharchive', 'gharchive_events') }}

)

SELECT
    event_date,
    event_hour,
    raw_event:id::STRING               AS event_id,
    raw_event:type::STRING             AS event_type,
    raw_event:actor.login::STRING      AS actor_login,
    raw_event:actor.type::STRING       AS actor_type,
    raw_event:repo.name::STRING        AS repo_name,
    raw_event:created_at::TIMESTAMP_TZ AS created_at

FROM source
