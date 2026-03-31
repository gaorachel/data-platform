-- Run once after terraform apply to create the external table.
-- AUTO_REFRESH = TRUE means Snowflake will automatically refresh
-- the table metadata when new files land in S3 via SQS notification.

USE DATABASE DATA_PLATFORM;
USE SCHEMA GHARCHIVE;
USE WAREHOUSE COMPUTE_WH;

CREATE EXTERNAL TABLE IF NOT EXISTS GHARCHIVE_EVENTS (
  EVENT_DATE DATE AS (CAST(SPLIT_PART(SPLIT_PART(metadata$filename, 'event_date=', 2), '/', 1) AS DATE)),
  EVENT_HOUR NUMBER AS (CAST(SPLIT_PART(SPLIT_PART(metadata$filename, 'event_hour=', 2), '/', 1) AS NUMBER)),
  RAW_EVENT VARIANT AS (value)
)
PARTITION BY (EVENT_DATE, EVENT_HOUR)
LOCATION = @DATA_PLATFORM.GHARCHIVE.GHARCHIVE_S3_STAGE
FILE_FORMAT = (TYPE = JSON)
AUTO_REFRESH = TRUE;
