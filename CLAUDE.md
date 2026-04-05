# CLAUDE.md

Instructions for Claude Code working on this repo. Read this before writing any code.

---

## Project context

A data engineering platform modelled on real-world practices. Prefer the correct pattern over the quick one, and always explain the tradeoff when there is one.

The owner is a mid-senior analytics engineer comfortable with Python, SQL, dbt, and Airflow. New to AWS and Terraform. Don't over-explain dbt or SQL, but do explain AWS/Terraform decisions clearly.

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
└── raw/github-repos/enriched_date=YYYY-MM-DD/
```

If unsure which bucket a new source belongs to, ask before writing any code.

---

## Hard rules — never break without explicit instruction

- **Respect data classification** — never mix general and restricted data across buckets
- **No Docker / no ECR** — Lambda is zip deploy only
- **No COPY INTO** — data stays in S3, queried via Snowflake external table
- **No USER_SPECIFIED partitions** — use `PARTITION_TYPE = AUTO`
- **No S3 Terraform backend yet** — state is local
- **No hardcoded secrets** — API keys go in AWS Secrets Manager, never in env vars, code, or tfvars
- **No requirements change without asking** — check before adding new Lambda dependencies
- **No shared Terraform state between projects** — each project is fully independent
- **`snowflake_external_table` is NOT managed by Terraform** — use `snowflake/setup.sql` and `snowflake/setup_repos.sql` instead (see Snowflake provider bug note below)
- **Snowflake provider** — use `snowflake-labs/snowflake` not `hashicorp/snowflake`

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

**S3 partitioning**
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

**Secrets**
- GitHub PAT: `data-platform/github/pat` in AWS Secrets Manager
- Lambda reads at runtime via boto3 — never in environment variables or code
- Snowflake credentials: `terraform/gharchive/snowflake.tfvars` (gitignored)
- GitHub Actions secrets:
  - `SNOWFLAKE_ACCOUNT` — org-account format e.g. `myorg-myaccount`
  - `SNOWFLAKE_USER` — Snowflake username
  - `SNOWFLAKE_SECRETS` — Snowflake password
  - `SNOWFLAKE_ROLE` — Snowflake role
  - `SNOWFLAKE_DATABASE` — Snowflake database
  - `SNOWFLAKE_WAREHOUSE` — Snowflake warehouse
  - `SNOWFLAKE_GH_ANALYSIS_SCHEMA` — schema for gh-analysis dbt models

**Terraform**
- `terraform/shared/` always applied first
- Use modules, never put everything in `main.tf`
- Variables in `variables.tf`, never hardcoded
- Never commit `.tfvars` files

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
- Terraform: lowercase resource names, underscores not hyphens, `description` on all variables
- SQL: uppercase keywords, snake_case identifiers
- Commit messages: `type(scope): description` e.g. `feat(gharchive): add enrichment lambda`

---

## When you are unsure

Ask before:
- Adding a new AWS service not in the architecture
- Changing an existing design decision
- Adding a Python dependency
- Modifying Terraform state
- Deciding which S3 bucket a new source belongs to
- Adding code outside the current project folder

Do not silently make a different choice and explain it afterwards.
