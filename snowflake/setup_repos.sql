-- Run once after terraform apply to set up the github-repos external table.
--
-- Prerequisites:
--   1. terraform apply has provisioned the Snowflake storage integration
--      (GHARCHIVE_S3_INTEGRATION) and the new IAM policy
--      (snowflake-s3-read-github-repos) on the Snowflake IAM role.
--   2. The IAM policy covers raw/github-repos/* on data-platform-main-*.
--
-- Step 1: extend the storage integration's allowed locations.
-- The integration was created by Terraform pointing at raw/gharchive/ only.
-- We add raw/github-repos/ here without removing the existing location.

USE DATABASE DATA_PLATFORM;
USE SCHEMA GHARCHIVE;
USE WAREHOUSE COMPUTE_WH;

ALTER STORAGE INTEGRATION GHARCHIVE_S3_INTEGRATION
  SET STORAGE_ALLOWED_LOCATIONS = (
    's3://data-platform-main-074308311757/raw/gharchive/',
    's3://data-platform-main-074308311757/raw/github-repos/'
  );

-- Step 2: create the external stage for github-repos data.
-- Reuses the existing storage integration (same bucket, different prefix).

CREATE STAGE IF NOT EXISTS GITHUB_REPOS_S3_STAGE
  STORAGE_INTEGRATION = GHARCHIVE_S3_INTEGRATION
  URL = 's3://data-platform-main-074308311757/raw/github-repos/'
  FILE_FORMAT = (TYPE = JSON);

-- Step 3: create the external table.
-- AUTO_REFRESH = FALSE because the singleton S3 bucket notification already
-- routes events for raw/gharchive/ to Snowflake's SQS queue and cannot be
-- extended without re-applying Terraform. The Lambda calls
-- ALTER EXTERNAL TABLE ... REFRESH after each write instead.

CREATE EXTERNAL TABLE IF NOT EXISTS GITHUB_REPOS (
  ENRICHED_DATE  DATE      AS (CAST(SPLIT_PART(SPLIT_PART(metadata$filename, 'enriched_date=', 2), '/', 1) AS DATE)),
  FULL_NAME      VARCHAR   AS (value:full_name::VARCHAR),
  LANGUAGE       VARCHAR   AS (value:language::VARCHAR),
  TOPICS         VARIANT   AS (value:topics::VARIANT),
  STARGAZERS_COUNT NUMBER  AS (value:stargazers_count::NUMBER),
  FORKS_COUNT    NUMBER    AS (value:forks_count::NUMBER),
  IS_FORK        BOOLEAN   AS (value:is_fork::BOOLEAN),
  CREATED_AT     TIMESTAMP_TZ AS (value:created_at::TIMESTAMP_TZ),
  DESCRIPTION    VARCHAR   AS (value:description::VARCHAR)
)
PARTITION BY (ENRICHED_DATE)
LOCATION = @DATA_PLATFORM.GHARCHIVE.GITHUB_REPOS_S3_STAGE
FILE_FORMAT = (TYPE = JSON)
AUTO_REFRESH = FALSE;
