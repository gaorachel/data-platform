WITH source AS (

    SELECT
        ENRICHED_DATE,
        value
    FROM {{ source('github', 'github_repo_metadata') }}

),

typed AS (

    SELECT
        value:full_name::STRING      AS repo_full_name,
        value:language::STRING       AS language,
        value:topics::VARIANT        AS topics,
        value:stargazers_count::INT  AS stargazers_count,
        value:forks_count::INT       AS forks_count,
        value:is_fork::BOOLEAN       AS is_fork,
        value:created_at::TIMESTAMP  AS repo_created_at,
        value:description::STRING    AS description,
        ENRICHED_DATE                AS enriched_date

    FROM source

)

SELECT
    repo_full_name,
    language,
    topics,
    stargazers_count,
    forks_count,
    is_fork,
    repo_created_at,
    description,
    enriched_date

FROM typed
QUALIFY ROW_NUMBER() OVER (PARTITION BY repo_full_name ORDER BY enriched_date DESC) = 1
