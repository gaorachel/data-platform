import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
import requests
import snowflake.connector
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    load_pem_private_key,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

S3_BUCKET = os.environ["S3_BUCKET"]
SECRET_NAME = os.environ["SECRET_NAME"]
SNOWFLAKE_ACCOUNT = os.environ["SNOWFLAKE_ACCOUNT"]
SNOWFLAKE_USER = os.environ["SNOWFLAKE_USER"]
SNOWFLAKE_PRIVATE_KEY_SECRET_NAME = os.environ["SNOWFLAKE_PRIVATE_KEY_SECRET_NAME"]
SNOWFLAKE_DATABASE = os.environ["SNOWFLAKE_DATABASE"]
SNOWFLAKE_SCHEMA = os.environ["SNOWFLAKE_SCHEMA"]
SNOWFLAKE_WAREHOUSE = os.environ["SNOWFLAKE_WAREHOUSE"]
TOP_N_REPOS = int(os.environ.get("TOP_N_REPOS", "100"))

GITHUB_API_BASE = "https://api.github.com"


def get_github_token() -> str:
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=SECRET_NAME)
    secret = json.loads(response["SecretString"])
    return secret["token"]


def get_snowflake_private_key() -> bytes:
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=SNOWFLAKE_PRIVATE_KEY_SECRET_NAME)
    pem = response["SecretString"].encode()
    key = load_pem_private_key(pem, password=None)
    return key.private_bytes(
        encoding=Encoding.DER,
        format=PrivateFormat.PKCS8,
        encryption_algorithm=NoEncryption(),
    )


def get_top_bot_repos(conn: snowflake.connector.SnowflakeConnection) -> list[str]:
    query = f"""
        SELECT repo_name, COUNT(*) AS bot_push_count
        FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.INT_GHARCHIVE__EVENTS_CLASSIFIED
        WHERE contributor_type = 'bot'
        GROUP BY repo_name
        ORDER BY bot_push_count DESC
        LIMIT {TOP_N_REPOS}
    """
    cursor = conn.cursor()
    cursor.execute(query)
    rows = cursor.fetchall()
    return [row[0] for row in rows]


def fetch_repo_metadata(owner: str, repo: str, token: str) -> dict | None:
    url = f"{GITHUB_API_BASE}/repos/{owner}/{repo}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    response = requests.get(url, headers=headers, timeout=10)

    if response.status_code == 404:
        logger.warning("Repo not found (deleted or private): %s/%s", owner, repo)
        return None

    response.raise_for_status()
    data = response.json()

    return {
        "full_name": data.get("full_name"),
        "language": data.get("language"),
        "topics": data.get("topics", []),
        "stargazers_count": data.get("stargazers_count"),
        "forks_count": data.get("forks_count"),
        "is_fork": data.get("fork"),
        "created_at": data.get("created_at"),
        "description": data.get("description"),
    }


def write_to_s3(records: list[dict], enriched_date: str, enriched_at: str) -> str:
    s3_key = f"raw/github-repos/enriched_date={enriched_date}/github_repos.json"
    ndjson = "\n".join(json.dumps(record) for record in records)

    s3 = boto3.client("s3")
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=s3_key,
        Body=ndjson.encode("utf-8"),
        ContentType="application/x-ndjson",
        Metadata={"enriched_at": enriched_at},
    )
    logger.info("Wrote %d records to s3://%s/%s", len(records), S3_BUCKET, s3_key)
    return s3_key


def refresh_external_table(conn: snowflake.connector.SnowflakeConnection) -> None:
    # AUTO_REFRESH is not configured for github-repos (would require a new SQS
    # notification, which conflicts with the singleton bucket notification already
    # managing gharchive). The Lambda refreshes the table itself after writing.
    try:
        conn.cursor().execute(
            f"ALTER EXTERNAL TABLE {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.GITHUB_REPOS REFRESH"
        )
        logger.info("External table GITHUB_REPOS refreshed")
    except snowflake.connector.errors.ProgrammingError as exc:
        # Table may not exist yet on first deploy — not fatal
        logger.warning("Could not refresh GITHUB_REPOS external table: %s", exc)


def lambda_handler(event: dict, context: object) -> dict:
    enriched_at = datetime.now(timezone.utc).isoformat()
    enriched_date = enriched_at[:10]  # YYYY-MM-DD

    logger.info("Starting github-repo-enrichment run for %s", enriched_date)

    conn = snowflake.connector.connect(
        account=SNOWFLAKE_ACCOUNT,
        user=SNOWFLAKE_USER,
        private_key=get_snowflake_private_key(),
        database=SNOWFLAKE_DATABASE,
        schema=SNOWFLAKE_SCHEMA,
        warehouse=SNOWFLAKE_WAREHOUSE,
    )

    try:
        repo_names = get_top_bot_repos(conn)
        logger.info("Fetched %d repos from Snowflake", len(repo_names))

        token = get_github_token()
        records: list[dict] = []
        not_found = 0

        for repo_name in repo_names:
            parts = repo_name.split("/", 1)
            if len(parts) != 2:
                logger.warning("Skipping malformed repo name: %s", repo_name)
                continue

            owner, repo = parts
            metadata = fetch_repo_metadata(owner, repo, token)

            if metadata is not None:
                records.append(metadata)
            else:
                not_found += 1

            time.sleep(0.1)  # respect GitHub API rate limits

        logger.info(
            "Fetched metadata for %d repos; %d not found", len(records), not_found
        )

        s3_key = write_to_s3(records, enriched_date, enriched_at)
        refresh_external_table(conn)

    finally:
        conn.close()

    return {
        "statusCode": 200,
        "enriched_date": enriched_date,
        "repos_fetched": len(records),
        "repos_not_found": not_found,
        "s3_key": s3_key,
    }
