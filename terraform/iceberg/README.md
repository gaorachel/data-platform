# terraform/iceberg

Infrastructure for the gharchive Iceberg lakehouse. Phase 1: catalog + compute
provisioning only. No data movement, no Spark jobs, no Snowflake integration.

---

## What this module provisions

| Resource                             | Purpose                                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| `aws_glue_catalog_database`          | Glue Data Catalog database `gharchive_iceberg` (eu-west-1). Holds Iceberg table metadata. |
| `aws_iam_role`                       | `gharchive-iceberg-emr-exec-role` — assumed by EMR Serverless job runs.                    |
| 4 × `aws_iam_role_policy` (inline)   | S3 raw read, S3 iceberg read-write, Glue catalog scope, CloudWatch Logs.                   |
| `aws_emrserverless_application`      | Spark application `gharchive-iceberg`, release `emr-7.12.0`, ARM64, pay-per-use.          |

No Iceberg tables are created here. The Spark writer in Phase 2 will issue
`CREATE TABLE IF NOT EXISTS` so table schema, partition spec, and sort order
live with the code that depends on them.

## EMR Serverless configuration

- **Release label:** `emr-7.12.0` (latest stable at time of writing, ships with
  Iceberg 1.10 natively — no jar upload step needed).
- **Architecture:** ARM64 / Graviton — ~20% cheaper than x86 for Spark workloads.
- **Pre-initialized capacity:** none. Workers spin up per job (cold start
  overhead ~60–90s, acceptable for a batch pipeline that runs on a schedule).
- **Maximum capacity:** 4 vCPU / 16 GB memory / 50 GB disk. Caps the blast
  radius of a runaway job at a few pounds per hour.
- **Auto-stop:** 15 minutes idle.
- **Auto-start:** enabled.

## IAM scope (execution role)

**Can:**

- Read `s3://data-platform-main-<account_id>/raw/gharchive/*`
- Read + write `s3://data-platform-main-<account_id>/iceberg/gharchive/*`
- Read + write the `gharchive_iceberg` Glue database and any tables inside it
  (current and future — tables are created at job time)
- Write CloudWatch Logs under `/aws/emr-serverless/*`

**Cannot:**

- Touch the restricted bucket (`data-platform-restricted-*`).
- Touch any other prefix in the main bucket (e.g. `raw/github-repos/`).
- Touch any other Glue database.
- Write logs outside the EMR Serverless log group pattern.
- Assume other roles or call Secrets Manager.

All four policies are inline on the role — no managed policies, no standalone
policy resources — so the permission surface is visible in one place.

## S3 `iceberg/gharchive/` prefix

Not created by Terraform. S3 prefixes are logical and come into existence
implicitly when the first object is written under them. The Spark writer in
Phase 2 will create the prefix on its first `INSERT`. This matches the
convention for `raw/gharchive/` (created by the ingestion Lambda on first
object write) and avoids the drift cost of managing a placeholder object.

`terraform/shared/main.tf` currently manages buckets and lifecycle rules only,
not prefixes — no change needed there.

## How to apply

Prerequisites:

- `terraform/shared/` has been applied and the main bucket exists.
- AWS credentials in the environment with permissions to create IAM, Glue, and
  EMR Serverless resources.

```sh
cd terraform/iceberg
terraform init
terraform plan  -var="s3_bucket_name=data-platform-main-<account_id>"
terraform apply -var="s3_bucket_name=data-platform-main-<account_id>"
```

State is stored independently at `s3://data-platform-tf-state-074308311757/iceberg/terraform.tfstate` with DynamoDB locking via `data-platform-tf-state-lock`.

## Expected cost at idle

**£0/month.**

- Glue database: free (first 1M objects in the Glue Data Catalog are free, and
  we'll have a handful).
- IAM role + inline policies: free.
- EMR Serverless application: no charge while idle. Billing is per vCPU-second
  and GB-second consumed by running jobs only. No pre-initialized capacity
  means no warm workers accumulating cost.

Cost starts accumulating only once Phase 2 submits job runs.

## What Phase 2 will need from this infra

- `emr_serverless_application_id` — passed to `StartJobRun` as `applicationId`.
- `emr_serverless_execution_role_arn` — passed to `StartJobRun` as
  `executionRoleArn`.
- `glue_database_name` — used as the catalog namespace in Spark config:
  `spark.sql.catalog.glue.warehouse = s3://data-platform-main-<id>/iceberg/gharchive/`
  and `spark.sql.catalog.glue = org.apache.iceberg.spark.SparkCatalog`.

Phase 2 will also need:

- An S3 location for Spark job scripts (separate prefix, not in scope here).
- A log delivery destination if CloudWatch Logs integration is wired up at the
  application level — currently the role has logs permissions but the
  application is not yet configured with `cloudwatch_logging_configuration`.
  That can be added when Phase 2 submits the first job.
