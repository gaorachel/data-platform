# gharchive ingestion

Hourly Lambda ingesting GitHub Archive event data into S3.

## Deploy

```bash
make build    # zip Lambda
make deploy   # deploy to AWS
make invoke   # test manually
```

## Environment variables

| Variable | Description |
|---|---|
| `S3_BUCKET` | Target S3 bucket — set by Terraform |

## S3 output

```
raw/gharchive/event_date=YYYY-MM-DD/event_hour=H/filename.json.gz
```

Partitioned by event time. `ingested_at` stored in S3 object metadata.

## Infrastructure

Provisioned by `terraform/gharchive/`. Key resources: Lambda (Python 3.12, 512MB, 300s), EventBridge cron at 5 past every hour, IAM scoped to `raw/gharchive/*`, S3 lifecycle to GLACIER at 90 days.
