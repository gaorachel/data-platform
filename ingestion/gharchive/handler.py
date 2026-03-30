import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import requests

logger = logging.getLogger()
logger.setLevel(logging.INFO)

S3_BUCKET = os.environ["S3_BUCKET"]
GHARCHIVE_BASE_URL = "https://data.gharchive.org"

s3 = boto3.client("s3")


def target_hour(now: datetime) -> datetime:
    """Return the most recently completed hour — the one Lambda should fetch."""
    return (now - timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)


def build_url(dt: datetime) -> str:
    # gharchive filenames use the hour as a bare integer (0–23), not zero-padded
    return f"{GHARCHIVE_BASE_URL}/{dt.strftime('%Y-%m-%d')}-{dt.hour}.json.gz"


def build_s3_key(dt: datetime) -> str:
    date_str = dt.strftime("%Y-%m-%d")
    filename = f"{date_str}-{dt.hour}.json.gz"
    return f"raw/gharchive/event_date={date_str}/event_hour={dt.hour}/{filename}"


def fetch_and_upload(url: str, s3_key: str, ingested_at: str) -> None:
    logger.info("Fetching %s", url)
    response = requests.get(url, timeout=120)
    response.raise_for_status()

    content = response.content
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=s3_key,
        Body=content,
        ContentType="application/gzip",
        Metadata={"ingested_at": ingested_at},
    )
    logger.info("Uploaded %d bytes to s3://%s/%s", len(content), S3_BUCKET, s3_key)


def lambda_handler(event: dict, context: object) -> dict:
    now = datetime.now(timezone.utc)
    target = target_hour(now)
    ingested_at = now.isoformat()

    url = build_url(target)
    s3_key = build_s3_key(target)

    fetch_and_upload(url, s3_key, ingested_at)

    return {
        "status": "ok",
        "url": url,
        "s3_key": s3_key,
        "ingested_at": ingested_at,
    }
