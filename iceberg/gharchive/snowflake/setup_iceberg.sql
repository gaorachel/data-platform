-- One-time setup for Snowflake's read-only access to the Iceberg `events` table
-- managed in the AWS Glue catalog (database: gharchive_iceberg, region: eu-west-1).
--
-- Run this AFTER the Spark job has created the Iceberg table at least once —
-- CATALOG_TABLE_NAME must resolve against Glue at CREATE ICEBERG TABLE time.
--
-- ┌──────────────────────────────────────────────────────────────────────────┐
-- │ Prerequisites (these CANNOT be automated here — do them manually in AWS) │
-- ├──────────────────────────────────────────────────────────────────────────┤
-- │ A) An IAM role  snowflake-iceberg-read-role                              │
-- │    - Trust policy: allow Snowflake's account (filled in after DESC       │
-- │      EXTERNAL VOLUME below) to AssumeRole with matching external ID.     │
-- │    - Inline policy: s3:GetObject, s3:GetObjectVersion on                 │
-- │      arn:aws:s3:::data-platform-main-074308311757/iceberg/*              │
-- │      + s3:ListBucket on the bucket with prefix iceberg/* condition.      │
-- │                                                                          │
-- │ B) An IAM role  snowflake-iceberg-glue-role                              │
-- │    - Trust policy: allow Snowflake (filled in after DESC CATALOG         │
-- │      INTEGRATION below).                                                 │
-- │    - Inline policy: glue:GetDatabase, glue:GetTable, glue:GetTables on   │
-- │      arn:aws:glue:eu-west-1:074308311757:catalog,                        │
-- │      arn:aws:glue:eu-west-1:074308311757:database/gharchive_iceberg,     │
-- │      arn:aws:glue:eu-west-1:074308311757:table/gharchive_iceberg/*.      │
-- │                                                                          │
-- │ The role ARNs plug into the CREATE statements below.                     │
-- └──────────────────────────────────────────────────────────────────────────┘
--
-- Two-step trust-policy dance (Snowflake requires this on every new volume /
-- catalog integration — no way around it):
--   1. Run CREATE OR REPLACE with a placeholder external ID.
--   2. DESC the object to read STORAGE_AWS_IAM_USER_ARN / STORAGE_AWS_EXTERNAL_ID
--      (or API_AWS_IAM_USER_ARN / API_AWS_EXTERNAL_ID for the catalog integration).
--   3. Paste those into the IAM role's trust policy in AWS.
--   4. Nothing to re-run in Snowflake — the trust update takes effect on the
--      next AssumeRole.

USE DATABASE DATA_PLATFORM;
USE SCHEMA GHARCHIVE;
USE WAREHOUSE COMPUTE_WH;

-- ── Step 1: external volume ───────────────────────────────────────────────
-- Snowflake reads Iceberg data/metadata files from S3. An external volume
-- gives it an IAM-bounded entry point — it can only read objects under the
-- configured STORAGE_BASE_URL, via the configured STORAGE_AWS_ROLE_ARN.
--
-- Base URL is set to s3://…/iceberg/ (not …/iceberg/gharchive/events/) so
-- the same volume can serve future Iceberg tables under this bucket.

CREATE OR REPLACE EXTERNAL VOLUME iceberg_data_platform_vol
  STORAGE_LOCATIONS = (
    (
      NAME             = 'iceberg-s3-eu-west-1',
      STORAGE_PROVIDER = 'S3',
      STORAGE_BASE_URL = 's3://data-platform-main-074308311757/iceberg/',
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::074308311757:role/snowflake-iceberg-read-role'
    )
  );

-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this output
-- into the trust policy of snowflake-iceberg-read-role.
DESC EXTERNAL VOLUME iceberg_data_platform_vol;

-- ── Step 2: Glue catalog integration ──────────────────────────────────────
-- This is how Snowflake discovers Iceberg tables' current metadata pointer
-- (snapshot location, schema, partition spec) without us having to re-register
-- the table every time Spark commits. CATALOG_NAMESPACE is the Glue database
-- — one integration can serve every table in the namespace.

CREATE OR REPLACE CATALOG INTEGRATION glue_gharchive_iceberg_int
  CATALOG_SOURCE    = GLUE
  CATALOG_NAMESPACE = 'gharchive_iceberg'
  TABLE_FORMAT      = ICEBERG
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::074308311757:role/snowflake-iceberg-glue-role'
  GLUE_CATALOG_ID   = '074308311757'
  GLUE_REGION       = 'eu-west-1'
  ENABLED           = TRUE;

-- Copy API_AWS_IAM_USER_ARN and API_AWS_EXTERNAL_ID from this output into
-- the trust policy of snowflake-iceberg-glue-role.
DESC CATALOG INTEGRATION glue_gharchive_iceberg_int;

-- ── Step 3: the Iceberg table ─────────────────────────────────────────────
-- EXTERNAL_VOLUME = where to read files.
-- CATALOG         = where to resolve the current snapshot.
-- CATALOG_TABLE_NAME = the Glue table name (the Spark job creates this as
--                     `events` under the `gharchive_iceberg` database).
-- AUTO_REFRESH = TRUE polls Glue on a fixed interval (~every 30s by default)
-- so Snowflake sees new snapshots without us running ALTER … REFRESH.

CREATE OR REPLACE ICEBERG TABLE GHARCHIVE_EVENTS_ICEBERG
  EXTERNAL_VOLUME    = 'iceberg_data_platform_vol'
  CATALOG            = 'glue_gharchive_iceberg_int'
  CATALOG_TABLE_NAME = 'events'
  AUTO_REFRESH       = TRUE;

-- ── Step 4: verify ────────────────────────────────────────────────────────
-- REFRESH forces a metadata read right now rather than waiting for the
-- auto-refresh tick. Useful first time so the COUNT below returns > 0.

ALTER ICEBERG TABLE GHARCHIVE_EVENTS_ICEBERG REFRESH;

SELECT COUNT(*) AS row_count
  FROM GHARCHIVE_EVENTS_ICEBERG;

SELECT
    DATE(CREATED_AT) AS event_date
  , COUNT(*)         AS row_count
  FROM GHARCHIVE_EVENTS_ICEBERG
 GROUP BY DATE(CREATED_AT)
 ORDER BY event_date;
