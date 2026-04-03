# data-platform

Analytics engineering platform ingesting, transforming, and serving data from multiple sources.

## Stack

| Layer | Tool |
|---|---|
| Ingestion | AWS Lambda, EventBridge |
| Storage | S3, Snowflake |
| Secrets | AWS Secrets Manager |
| Infrastructure | Terraform |
| Transformation | dbt |
| Serving | Lightdash, Streamlit |
| Language | Python, SQL (Snowflake) |
| CI/CD | GitHub Actions |

## Projects

| Project | Status | Description |
|---|---|---|
| [gharchive](ingestion/gharchive/README.md) | Active | Hourly GitHub public event ingestion |
| openssh-logs | Planned | Security log analytics |

## GitHub analysis pipelines

Two pipelines feed the GitHub analysis layer — hourly event ingestion from GitHub Archive and weekly repository metadata enrichment from the GitHub REST API.

![GitHub analysis architecture](docs/gh-analysis-architecture.svg)

## Running locally

```bash
# provision shared infra first
cd terraform/shared && terraform init && terraform apply

# provision project infra
cd ../gharchive && terraform init && terraform apply -var-file="snowflake.tfvars"

# deploy and test
make deploy && make invoke
```

See individual project READMEs for details.

## Docs

- [`docs/gh-analysis-architecture.svg`](docs/gh-analysis-architecture.svg) — GitHub analysis pipeline architecture
- [`docs/decisions/`](docs/decisions/) — architecture decision records

## S3 bucket strategy

Buckets are split by data classification, not by source:

| Bucket | Classification | Use for |
|---|---|---|
| `s3://data-platform-main-<account_id>/` | General | Public, non-sensitive analytics data |
| `s3://data-platform-restricted-<account_id>/` | Restricted | Security logs, PII, compliance data |
