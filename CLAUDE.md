# CLAUDE.md

Instructions for Claude Code working on this repo. Read this before writing any code.

---

## Project context

A data engineering platform modelled on real-world practices. Prefer the correct pattern over the quick one, and always explain the tradeoff when there is one.

The owner is a senior analytics engineer comfortable with Python, SQL, dbt, and Airflow. New to AWS and Terraform. Learning Spark, Iceberg, and Kafka through this platform. Don't over-explain dbt or SQL, but do explain AWS/Terraform/Spark/Iceberg decisions clearly.

---

## S3 bucket strategy

Buckets are split by **data classification**, not by source or domain.

| Bucket | Classification | Use for | Controls |
|---|---|---|---|
| `s3://data-platform-main-<account_id>/` | General | Public, non-sensitive analytics data | Standard IAM, prefix-scoped per Lambda |
| `s3://data-platform-restricted-<account_id>/` | Restricted | Security logs, PII, PCI, compliance data | Separate KMS key, CloudTrail enabled, strict IAM |

General analytics sources share `data-platform-main`, separated by prefix:
```
s3://data-platform-main-<account_id>/
├── raw/gharchive/event_date=YYYY-MM-DD/event_hour=H/
├── raw/github-repos/enriched_date=YYYY-MM-DD/
└── iceberg/gharchive/                   # Iceberg table data + metadata
```

If unsure which bucket a new source belongs to, ask before writing any code.

---

## Hard rules — never break without explicit instruction

- **Respect data classification** — never mix general and restricted data across buckets
- **No Docker / no ECR** — Lambda is zip deploy only
- **No COPY INTO** — data stays in S3, queried via Snowflake external table or Iceberg table
- **No USER_SPECIFIED partitions** — use `PARTITION_TYPE = AUTO` for Snowflake external tables
- **Terraform remote state** — S3 backend at `data-platform-tf-state-074308311757` (eu-west-1), DynamoDB locking via `data-platform-tf-state-lock`; keys: `shared/terraform.tfstate`, `gharchive/terraform.tfstate`, `iceberg/terraform.tfstate`
- **No hardcoded secrets** — API keys go in AWS Secrets Manager, never in env vars, code, or tfvars
- **No requirements change without asking** — check before adding new Lambda or Spark dependencies
- **No shared Terraform state between projects** — each project is fully independent
- **`snowflake_external_table` is NOT managed by Terraform** — use `snowflake/setup.sql` and `snowflake/setup_repos.sql` instead (see Snowflake provider bug note below)
- **Snowflake provider** — use `snowflake-labs/snowflake` not `hashicorp/snowflake`
- **Iceberg tables are NOT created by Terraform** — tables are created by the writing engine (Spark) via `CREATE TABLE IF NOT EXISTS`. Terraform provisions the Glue database only.
- **One phase, one PR** — each project phase goes on its own feature branch (`feat/<project>-phase<N>-<description>`) and has its own PR. No phase starts until the previous is merged.
- **No autonomous architectural decisions** — if a decision hasn't been agreed in chat, stop and ask. Do not silently pick a different approach.

---

## Snowflake provider bug

`snowflake_external_table` causes a panic in `snowflake-labs/snowflake` v1.x on import:
```
panic: interface conversion: sdk.ObjectIdentifier is sdk.AccountObjectIdentifier,
not sdk.SchemaObjectIdentifier
```

External tables are managed via SQL files instead. Run these once after `terraform apply`:
- `snowflake/setup.sql` — creates `GHARCHIVE_EVENTS`
- `snowflake/setup_repos.sql` — creates `GITHUB_REPO_METADATA`, extends storage integration allowed locations

Do not attempt to add `snowflake_external_table` back to Terraform unless the bug is confirmed fixed.

---

## Architecture decisions

**S3 partitioning (raw zone)**
Partitioned by event time, not ingestion time. `ingested_at` in S3 object metadata only.
```
raw/<source>/event_date=YYYY-MM-DD/event_hour=H/filename
```

**Snowflake AUTO_REFRESH**
S3 event notifications point at Snowflake's managed SQS queue (`sf-snowpipe-...`). No customer-managed SQS queue. AUTO_REFRESH triggers automatically when new files land.

**Lambda**
- Runtime: Python 3.12, zip deploy
- gharchive: 512MB, 300s, IAM scoped to `raw/gharchive/*`
- github-repos: 256MB, 300s, IAM scoped to `raw/github-repos/*` and Secrets Manager PAT secret

**Iceberg (gharchive_iceberg project)**
- Catalog: AWS Glue Data Catalog (database: `gharchive_iceberg`, region: eu-west-1)
- Write engine: PySpark on EMR Serverless (arm64/Graviton, pay-per-use, no pre-initialized capacity)
- Read engines: Snowflake (external Iceberg table via Glue catalog integration) and Athena
- File format: Parquet with ZSTD compression
- Partitioning: hidden partitioning via `days(created_at)` transform — no materialised `event_date`/`event_hour` columns on the Iceberg table
- Partition evolution: planned demo — evolve to `hours(created_at)` for recent data while old data stays on daily partitions
- Table location: `s3://data-platform-main-<account_id>/iceberg/gharchive/events/`
- Table DDL: created by the Spark job (`CREATE TABLE IF NOT EXISTS`), not Terraform

**Rationale for Glue over Polaris / S3 Tables**
Glue is the most widely deployed Iceberg catalog in AWS shops today and integrates natively with EMR Serverless, Athena, and Snowflake. Polaris (REST catalog, vendor-neutral) is where the industry is moving but still maturing; revisit for any greenfield multi-cloud deployment. S3 Tables abstracts too much away to be useful for learning Iceberg fundamentals.

**Secrets**
- GitHub PAT: `data-platform/github/pat` in AWS Secrets Manager
- Lambda reads at runtime via boto3 — never in environment variables or code
- Snowflake credentials: `terraform/gharchive/snowflake.tfvars` (gitignored)
- GitHub Actions secrets:
  - `SNOWFLAKE_ACCOUNT` — org-account format e.g. `myorg-myaccount`
  - `SNOWFLAKE_USER` — Snowflake username
  - `SNOWFLAKE_PASSWORD` — Snowflake password
  - `AWS_ACCESS_KEY_ID` — AWS access key ID for CI/CD (terraform plan, lambda build verification)
  - `AWS_SECRET_ACCESS_KEY` — AWS secret access key for CI/CD
  - `LIGHTDASH_API_KEY`

**Terraform**
- `terraform/shared/` always applied first
- Use modules, never put everything in `main.tf`
- Variables in `variables.tf`, never hardcoded
- Never commit `.tfvars` files
- Each project has its own state key; no shared state across projects

**dbt**
- Staging: view materialisation
- Intermediate: view materialisation
- Marts: incremental table, delete+insert, last 3 days incremental filter
- All models include Lightdash meta tags
- Dashboard YAML definitions in `dbt/lightdash/`
- Do not change materialisation without asking

**Snowflake connection**
- Database: `DATA_PLATFORM`
- Schema: `GHARCHIVE`
- Warehouse: `COMPUTE_WH`

---

## Code style

- Python: PEP8, type hints, small single-purpose functions
- PySpark: prefer DataFrame API over Spark SQL strings; keep transformations pure and chainable; no `spark.sql("...")` with embedded variables unless there's a clear reason
- Terraform: lowercase resource names, underscores not hyphens, `description` on all variables
- SQL (Snowflake): uppercase keywords, snake_case identifiers, comma-before-FROM style
- Commit messages: `type(scope): description` e.g. `feat(iceberg): add glue database and emr iam`

---

## When you are unsure

Ask before:
- Adding a new AWS service not in the architecture
- Changing an existing design decision
- Adding a Python or Spark dependency
- Modifying Terraform state
- Deciding which S3 bucket a new source belongs to
- Adding code outside the current project folder
- Choosing an Iceberg table property, partitioning spec, or sort order not already specified

Do not silently make a different choice and explain it afterwards.