WITH push_events AS (

    SELECT *
    FROM {{ ref('stg_gharchive__events') }}
    WHERE event_type = 'PushEvent'

),

classified AS (

    SELECT
        event_date,
        event_hour,
        event_id,
        event_type,
        created_at,
        actor_login,
        actor_type,
        repo_name,
        CASE
            WHEN actor_type = 'Bot'
                OR actor_login ILIKE '%[bot]%'
                OR actor_login ILIKE '%-bot'
                OR actor_login ILIKE '%-ci'
                OR actor_login ILIKE '%-automation'
            THEN TRUE
            ELSE FALSE
        END AS is_bot

    FROM push_events

)

SELECT
    event_date,
    event_hour,
    event_id,
    event_type,
    created_at,
    actor_login,
    actor_type,
    repo_name,
    is_bot,
    CASE WHEN is_bot THEN 'bot' ELSE 'human' END AS contributor_type

FROM classified
