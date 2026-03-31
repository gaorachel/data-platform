# CLAUDE.md

Instructions for Claude Code working on this repo. Read this before writing any code.

---

## Project context

This is a data engineering platform modelled on real-world practices. The primary goal is learning AWS, Terraform, and analytics engineering patterns — not just getting something working. Prefer the correct pattern over the quick one, and always explain the tradeoff when there is one.

The owner is a mid-senior analytics engineer comfortable with Python, SQL, dbt, and Airflow. New to AWS and Terraform. Explanations should reflect that — don't over-explain dbt or SQL, but do explain AWS/Terraform decisions clearly.

---

## Repo structure

```
data-platform/
├── ingestion/
│   ├── gharchive/               # Lambda function + dependencies
│   └── openssh-logs/            # future — security project
├── terraform/
│   ├── shared/                  # shared infra: S3 buckets, KMS keys — apply first
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── gharchive/               # independent state, references shared bucket
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── modules/
│   │       ├── s3/main.tf
│   │       ├── lambda/main.tf
│   │       └── ecr/main.tf
│   └── openssh-logs/            # future — own state, references restricted bucket
├── dbt/                         # shared across all sources
├── streamlit/
├── Makefile
├── README.md
└── CLAUDE.md
```

`terraform/shared/` is always applied first — it provisions the S3 buckets and KMS keys that project-level Terraform references. When adding a new ingestion source, create `ingestion/<source-name>/` and `terraform/<source-name>/` with its own independent state.

---

## S3 bucket strategy — classification drives design

Both buckets are data lakes. They are split by **data classification**, not by domain or source. Bucket names reflect access level so the naming stays valid as new sources are added over time.

| Bucket | Classification | Use for | Controls |
|---|---|---|---|
| `s3://data-platform-main/` | General | Public data, non-sensitive analytics sources | Standard IAM, prefix-scoped per Lambda |
| `s3://data-platform-restricted/` | Restricted | Security logs, PII, PCI, compliance-sensitive data | Separate KMS key, CloudTrail enabled, strict IAM |

**Naming rationale:**
- `main` — primary landing zone for general analytics. Not named after a domain (e.g. "analytics" or "lake") so it stays accurate as sources are added.
- `restricted` — signals access-controlled data regardless of domain, such as Security logs or other PII, PCI type of data.

**General analytics sources** (e.g. gharchive) land in `data-platform-main/`, separated by prefix:
```
s3://data-platform-main/
└── raw/gharchive/event_date=YYYY-MM-DD/event_hour=H/
```

**Restricted sources** (e.g. openssh-logs, future PII, PCI sources) land in `data-platform-restricted/` — never in `data-platform-main/`.

If unsure which bucket a new source belongs to, ask before writing any code.

---

## Hard rules — never break these without explicit instruction

- **Respect data classification** — restricted/PII data goes to `data-platform-restricted/`, general analytics goes to `data-platform-main/`. Never mix them.
- **No Docker / no ECR** — Lambda is zip deploy only. Do not add a Dockerfile unless asked.
- **No COPY INTO** — data stays in S3, queried via Snowflake external table. Do not suggest or write COPY INTO.
- **No USER_SPECIFIED partitions** — Snowflake external table uses `PARTITION_TYPE = AUTO`.
- **No S3 Terraform backend yet** — state is local. Do not add a backend block unless asked.
- **No second Lambda for Snowflake** — AUTO_REFRESH via SQS handles Snowflake updates automatically.
- **No requirements change without asking** — `requests` and `boto3` are the only Lambda dependencies.
- **No shared Terraform state between projects** — each project under `terraform/` is fully independent. Shared infra lives in `terraform/shared/` with its own state.
- **`snowflake_external_table` is not managed by Terraform** — the Snowflake provider v1.x has a bug that prevents creating external tables with `AUTO_REFRESH = TRUE`. The `GHARCHIVE_EVENTS` external table is defined in `snowflake/setup.sql` and must be run manually once after `terraform apply`.

---

## Architecture decisions to respect

**S3 partitioning**
S3 keys within each bucket follow this convention:
```
raw/<source>/event_date=YYYY-MM-DD/event_hour=H/filename
```
Partitioned by event time (the hour the data represents), not ingestion time. `ingested_at` is stored in S3 object metadata only.

**Lambda**
- Runtime: Python 3.12
- Deploy: zip package
- Timeout: 300s
- Memory: 512MB
- IAM: scoped to `s3:PutObject` on `raw/<source>/*` prefix only — least privilege, never grant access to the full bucket or another source's prefix

**Terraform**
- `terraform/shared/` provisions S3 buckets and KMS keys — always apply this first
- Project-level Terraform references shared outputs via input variables
- Use modules — do not put everything in `main.tf`
- One module per AWS service: `s3`, `lambda`, `ecr`
- Variables go in `variables.tf`, never hardcoded in resource blocks
- Never commit `.tfvars` files

**dbt**
- Staging models: `view` materialisation
- Mart models: `table` materialisation, incremental where possible
- All sources feed the same shared dbt project under `dbt/`
- Do not change materialisation type without asking

---

## Current phase

**Phase 1 — Ingestion (active)**
EventBridge (cron 5 past every hour) → Lambda → `s3://data-platform-main/raw/gharchive/`

Phase 2 and beyond are planned but not started. Do not write Phase 2 code unless explicitly asked. The `openssh-logs` project is planned but not started — do not create code for it unless asked.

---

## Code style

- Python: PEP8, type hints, small single-purpose functions
- Terraform: lowercase resource names, underscores not hyphens, always include `description` on variables
- SQL: uppercase keywords, snake_case identifiers
- Commit messages: `type: short description` e.g. `feat: add gharchive lambda`, `chore: init terraform modules`

---

## When you are unsure

Ask before:
- Adding a new AWS service not already in the architecture
- Changing an existing design decision
- Adding a Python dependency to `requirements.txt`
- Modifying Terraform state configuration
- Deciding which S3 bucket a new data source belongs to
- Adding code to a project folder other than the one being worked on

Do not silently make a different choice and explain it afterwards.
