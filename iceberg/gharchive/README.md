# iceberg/gharchive

Phase 2 of the gharchive Iceberg project: a PySpark job on EMR Serverless
that lands raw gharchive hourly JSON into an Iceberg table queryable from
Snowflake and Athena.

## What this pipeline does

```
s3://data-platform-main-<acct>/raw/gharchive/event_date=YYYY-MM-DD/event_hour=H/*.json.gz
        │
        │  jobs/load_gharchive_to_iceberg.py
        │  (EMR Serverless, Spark 3.5 + Iceberg 1.10 bundled in emr-7.12.0)
        ▼
glue_catalog.gharchive_iceberg.events
  · file format:  parquet + zstd
  · partitioned:  days(created_at)           (hidden partitioning)
  · location:     s3://data-platform-main-<acct>/iceberg/gharchive/events/
        │
        ├── Snowflake:  DATA_PLATFORM.GHARCHIVE.GHARCHIVE_EVENTS_ICEBERG
        │               (external Iceberg table via Glue catalog integration)
        └── Athena:     gharchive_iceberg.events
                        (direct read from the Glue catalog)
```

Idempotent: re-running for the same date range does a partition-level
`INSERT OVERWRITE` — only the `days(created_at)` partitions in the input are
replaced; everything else is untouched.

## Layout

```
iceberg/gharchive/
├── jobs/
│   └── load_gharchive_to_iceberg.py   # PySpark driver
├── snowflake/
│   └── setup_iceberg.sql              # one-time external volume + catalog + table
├── athena/
│   └── example_queries.sql            # reference queries incl. $snapshots
├── Makefile                           # upload-job / submit / logs / status
├── .env.example                       # copy to .env and fill in from terraform output
└── README.md
```

## Prerequisites

- `terraform/shared/` applied (main bucket exists).
- `terraform/iceberg/` applied (Glue database, EMR Serverless app, exec role).
  **This phase assumes Phase 1 is already deployed.** If `terraform output`
  doesn't return the EMR app ID, run `terraform apply` in that directory first.
- AWS credentials in the environment for the account that owns the infra.
- Raw gharchive data already in `s3://<bucket>/raw/gharchive/` for the date
  range you want to load (the existing gharchive Lambda pipeline populates this).

## How to run, end-to-end

### 1. Populate `.env`

```sh
cd iceberg/gharchive
cp .env.example .env

# Pull values from terraform outputs:
cd ../../terraform/iceberg
terraform init    # first time only
terraform output
# Copy emr_serverless_application_id and emr_serverless_execution_role_arn
# back into iceberg/gharchive/.env.
```

### 2. Upload the job to S3

EMR Serverless reads `entryPoint` from S3, not from the local filesystem.

```sh
cd iceberg/gharchive
make upload-job
```

### 3. Submit a job run

```sh
make submit START=2026-04-01 END=2026-04-14
# → prints jobRunId
```

The submit returns immediately with a `jobRunId`. On the first run the Spark
job runs `CREATE TABLE IF NOT EXISTS`, then `INSERT OVERWRITE` for the range.

### 4. Watch logs / check status

```sh
make logs   JOB_ID=<jobRunId>   # tails the CloudWatch log stream, Ctrl-C to stop
make status JOB_ID=<jobRunId>   # prints state, duration, billed capacity
```

Job-run states progress `SUBMITTED → PENDING → SCHEDULED → RUNNING → SUCCESS`
(or `FAILED`). Cold start is typically 60–90s before you see driver log lines.

### 5. Verify

**Athena:** run the queries in `athena/example_queries.sql`. `USE gharchive_iceberg` first.

**Snowflake:** first-time setup is manual — see the next section. After that:
```sql
SELECT COUNT(*) FROM DATA_PLATFORM.GHARCHIVE.GHARCHIVE_EVENTS_ICEBERG;
```

## Snowflake Iceberg integration — manual setup (one-time)

`snowflake_external_table` is managed via SQL in this repo (see the provider
bug note in `CLAUDE.md`). Iceberg tables follow the same pattern, plus they
need two AWS IAM roles that Snowflake assumes at read time. These **cannot**
be provisioned by `terraform/iceberg` because Snowflake generates the IAM
user ARN and external ID only after the external volume / catalog integration
is created.

The dance:

1. **Create two IAM roles in AWS** with empty trust policies for now:
   - `snowflake-iceberg-read-role` — inline policy allowing
     `s3:GetObject`, `s3:GetObjectVersion` on
     `arn:aws:s3:::data-platform-main-074308311757/iceberg/*` and
     `s3:ListBucket` on the bucket scoped to the `iceberg/*` prefix.
   - `snowflake-iceberg-glue-role` — inline policy allowing
     `glue:GetDatabase`, `glue:GetTable`, `glue:GetTables` on
     `arn:aws:glue:eu-west-1:074308311757:catalog`,
     `…:database/gharchive_iceberg`, `…:table/gharchive_iceberg/*`.

2. **In Snowflake, run `snowflake/setup_iceberg.sql` up to and including the
   two `DESC` statements.** Each `DESC` prints an IAM user ARN and external ID
   that Snowflake will use to assume the role.

3. **Back in AWS, paste those into each role's trust policy:**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "AWS": "<STORAGE_AWS_IAM_USER_ARN or API_AWS_IAM_USER_ARN>" },
       "Action": "sts:AssumeRole",
       "Condition": { "StringEquals": { "sts:ExternalId": "<external id>" } }
     }]
   }
   ```

4. **Run the rest of `snowflake/setup_iceberg.sql`** — the `CREATE ICEBERG TABLE`
   and verification queries.

Once done, Snowflake auto-refreshes the table metadata on a ~30s tick and
subsequent Spark writes are visible in Snowflake without any manual refresh.

## Expected runtime and cost for a 14-day load

Reference run: `2026-04-01 → 2026-04-14`, job `00g55dl97kt8ho0r`.

| Metric                       | Reference run              |
| ---------------------------- | -------------------------- |
| Job duration (wall-clock)    | 8 min (480 s execution)    |
| Records written              | 51,945,869                 |
| Output Iceberg table size    | 10.9 GiB (84 objects)      |
| Billed vCPU-hours            | 1.751                      |
| Billed memory GB-hours       | 7.613                      |
| EMR Serverless cost per run  | ~£0.11                     |
| Athena cost for verification | <£0.01 (data scanned)      |
| Snowflake cost               | warehouse time only        |

The `billedResourceUtilization` field on the job-run response (visible via
`make status`) has the authoritative numbers. Multiply: vCPU-hours × $0.052624
+ memoryGB-hours × $0.0057785 for exact cost (ARM64, eu-west-1).

## Rerunning / backfilling

Because `INSERT OVERWRITE` runs in `dynamic` partition mode, re-submitting the
same date range is safe and replaces only the partitions in that range. To add
a new day: just submit it (`make submit START=... END=...`) — the Iceberg
table gains one new partition, existing ones are untouched.

## What's NOT in this phase

- Schema evolution (Phase 3).
- Time-travel queries beyond the single `$snapshots` example (Phase 3).
- Partition evolution from daily → hourly for recent data (Phase 3).
- Scheduled/recurring runs (manual `make submit` only).
- Unit tests (correctness is verified by running against real data).
- dbt models on top of the Iceberg table.
