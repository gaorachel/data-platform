"""
Load raw gharchive hourly JSON from S3 into the Iceberg events table.

Reads  s3://<bucket>/raw/gharchive/event_date=YYYY-MM-DD/event_hour=H/*.json.gz
Writes glue_catalog.gharchive_iceberg.events

Idempotent: re-running for the same range performs a partition-level
INSERT OVERWRITE. Only the days(created_at) partitions that appear in the
input are replaced; every other partition is untouched.

Usage (submitted via spark-submit on EMR Serverless):
    load_gharchive_to_iceberg.py \\
        --start-date 2026-04-01 \\
        --end-date   2026-04-14 \\
        --bucket     data-platform-main-074308311757
"""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import date, datetime, timedelta
from typing import List

import boto3
from pyspark.sql import DataFrame, SparkSession
from pyspark.sql.functions import col, to_json, to_timestamp
from pyspark.sql.types import (
    BooleanType,
    LongType,
    StringType,
    StructField,
    StructType,
)


# Three-part table name: <catalog>.<database>.<table>. `glue_catalog` is the
# Iceberg-on-Glue catalog configured via spark-submit --conf.
TABLE_FQN = "glue_catalog.gharchive_iceberg.events"

# Raw prefix layout is owned by the gharchive Lambda pipeline.
RAW_PREFIX = "raw/gharchive"

# Explicit LOCATION pins the Iceberg data files to iceberg/gharchive/events/.
# The EMR execution role only has S3 write access under iceberg/gharchive/*,
# and the default Glue-catalog location would resolve to
# iceberg/gharchive_iceberg/events/ (outside that scope), so we override it.
TABLE_LOCATION_TEMPLATE = "s3://{bucket}/iceberg/gharchive/events/"


# ── Nested struct schemas ────────────────────────────────────────────────────
# Declared once, reused for: (1) casting the inferred DataFrame to a stable
# shape on read, (2) the CREATE TABLE DDL. If gharchive ever adds a field
# inside actor/repo/org, the cast will drop it — intentional, because schema
# evolution is out of scope for this phase.

ACTOR_STRUCT = StructType([
    StructField("id", LongType()),
    StructField("login", StringType()),
    StructField("display_login", StringType()),
    StructField("gravatar_id", StringType()),
    StructField("url", StringType()),
    StructField("avatar_url", StringType()),
])

REPO_STRUCT = StructType([
    StructField("id", LongType()),
    StructField("name", StringType()),
    StructField("url", StringType()),
])

ORG_STRUCT = StructType([
    StructField("id", LongType()),
    StructField("login", StringType()),
    StructField("gravatar_id", StringType()),
    StructField("url", StringType()),
    StructField("avatar_url", StringType()),
])


def parse_args(argv: List[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Load gharchive raw JSON into the Iceberg events table.",
    )
    p.add_argument("--start-date", required=True, help="Inclusive, YYYY-MM-DD")
    p.add_argument("--end-date", required=True, help="Inclusive, YYYY-MM-DD")
    p.add_argument(
        "--bucket",
        required=True,
        help="S3 bucket holding raw/ and iceberg/ prefixes (e.g. data-platform-main-<acct>)",
    )
    return p.parse_args(argv)


def date_range(start: date, end: date) -> List[date]:
    if end < start:
        raise ValueError(f"--end-date {end} is before --start-date {start}")
    return [start + timedelta(days=i) for i in range((end - start).days + 1)]


def assert_prefixes_exist(bucket: str, dates: List[date]) -> None:
    """Fail fast if any date in the range has no raw files.

    Silently skipping a missing date would produce a partial re-run: the
    requested range's partitions would be overwritten for dates that have
    data and left stale for dates that don't, which is exactly the kind of
    silent drift that's hard to notice later. Stop early instead.
    """
    s3 = boto3.client("s3")
    missing: List[str] = []
    for d in dates:
        prefix = f"{RAW_PREFIX}/event_date={d.isoformat()}/"
        resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1)
        if resp.get("KeyCount", 0) == 0:
            missing.append(prefix)
    if missing:
        raise FileNotFoundError(
            f"No raw files found for {len(missing)} prefix(es): " + ", ".join(missing)
        )


def build_source_paths(bucket: str, dates: List[date]) -> List[str]:
    # One glob per date — Spark expands the event_hour=*/*.json.gz wildcards.
    return [
        f"s3://{bucket}/{RAW_PREFIX}/event_date={d.isoformat()}/event_hour=*/*.json.gz"
        for d in dates
    ]


def ensure_table(spark: SparkSession, bucket: str) -> None:
    """Create the Iceberg table if it doesn't exist. Safe to run every time.

    - USING iceberg routes the CREATE through the Iceberg catalog.
    - PARTITIONED BY (days(created_at)) is Iceberg *hidden* partitioning:
      no materialised event_date column on the table, but readers still get
      partition pruning when they filter on created_at directly.
    - write.format.default + zstd give smaller files than the snappy default
      with comparable CPU; worth the swap for JSON-heavy event data.
    """
    location = TABLE_LOCATION_TEMPLATE.format(bucket=bucket)
    ddl = f"""
    CREATE TABLE IF NOT EXISTS {TABLE_FQN} (
        id         STRING,
        type       STRING,
        actor      STRUCT<
            id:            BIGINT,
            login:         STRING,
            display_login: STRING,
            gravatar_id:   STRING,
            url:           STRING,
            avatar_url:    STRING
        >,
        repo       STRUCT<
            id:   BIGINT,
            name: STRING,
            url:  STRING
        >,
        payload    STRING,
        public     BOOLEAN,
        created_at TIMESTAMP,
        org        STRUCT<
            id:          BIGINT,
            login:       STRING,
            gravatar_id: STRING,
            url:         STRING,
            avatar_url:  STRING
        >
    )
    USING iceberg
    PARTITIONED BY (days(created_at))
    LOCATION '{location}'
    TBLPROPERTIES (
        'write.format.default'            = 'parquet',
        'write.parquet.compression-codec' = 'zstd'
    )
    """
    spark.sql(ddl)


def read_source(spark: SparkSession, paths: List[str]) -> DataFrame:
    """Read all hourly .json.gz files across the date range.

    Schema inference is fine here: 2 weeks × 24 hours = 336 files, the
    pre-scan is cheap, and gharchive's top-level shape is stable.

    Casting nested structs to our declared shape keeps the DataFrame schema
    deterministic regardless of per-file variation. If gharchive introduces
    a new field inside actor/repo/org it is dropped — we'd rather notice on
    schema evolution (next phase) than silently widen the table.

    `payload` is flattened to a JSON string. gharchive payloads differ by
    event type (PushEvent vs PullRequestEvent etc.), so storing a typed
    struct would require a huge sparse union. A raw-JSON column stays
    stable, and readers can parse it on demand with get_json_object/
    from_json.
    """
    raw = spark.read.json(paths)
    return raw.select(
        col("id").cast(StringType()).alias("id"),
        col("type").cast(StringType()).alias("type"),
        col("actor").cast(ACTOR_STRUCT).alias("actor"),
        col("repo").cast(REPO_STRUCT).alias("repo"),
        to_json(col("payload")).alias("payload"),
        col("public").cast(BooleanType()).alias("public"),
        # gharchive serialises created_at as ISO-8601 with a trailing Z.
        # to_timestamp autodetects that format; being explicit avoids
        # surprises if a future Spark default changes.
        to_timestamp(col("created_at")).alias("created_at"),
        col("org").cast(ORG_STRUCT).alias("org"),
    )


def log_source_counts(logger: logging.Logger, df: DataFrame) -> int:
    total = df.count()
    logger.info("source records read: %d", total)
    per_date = (
        df.selectExpr("date(created_at) AS event_date")
          .groupBy("event_date")
          .count()
          .orderBy("event_date")
          .collect()
    )
    for row in per_date:
        logger.info("  source event_date=%s count=%d", row["event_date"], row["count"])
    return total


def log_target_counts(
    logger: logging.Logger,
    spark: SparkSession,
    start: date,
    end: date,
) -> None:
    """Read back the partitions we just wrote and log per-partition counts.

    Confirms round-trip: written count should equal source count. Filter is
    on created_at (the partition source column) so Iceberg prunes to only
    the days we touched — no full table scan.
    """
    upper_exclusive = (end + timedelta(days=1)).isoformat()
    per_date = (
        spark.table(TABLE_FQN)
             .filter(f"created_at >= '{start.isoformat()}' AND created_at < '{upper_exclusive}'")
             .selectExpr("date(created_at) AS event_date")
             .groupBy("event_date")
             .count()
             .orderBy("event_date")
             .collect()
    )
    logger.info("target table row counts after write:")
    for row in per_date:
        logger.info("  target event_date=%s count=%d", row["event_date"], row["count"])


def write_partitions(spark: SparkSession, df: DataFrame) -> None:
    """Dynamic partition overwrite — replace only partitions present in df.

    Iceberg's INSERT OVERWRITE honours spark.sql.sources.partitionOverwriteMode:
      - dynamic: replace partitions covered by the SELECT, keep others. ← what we want
      - static (default): truncate the whole table, then insert. ← not what we want

    SQL (not DataFrame API) is used for the INSERT because the DataFrame
    equivalent `df.writeTo(...).overwritePartitions()` reads a touch less
    explicitly about what "overwrite" means in Iceberg — the SQL form keeps
    the intent visible on the page.
    """
    spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
    df.createOrReplaceTempView("source_events")
    spark.sql(f"""
        INSERT OVERWRITE {TABLE_FQN}
        SELECT id, type, actor, repo, payload, public, created_at, org
        FROM source_events
    """)


def main(argv: List[str] | None = None) -> int:
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s - %(message)s",
        level=logging.INFO,
        stream=sys.stdout,
    )
    logger = logging.getLogger("gharchive_to_iceberg")

    args = parse_args(argv)
    start = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    end = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    dates = date_range(start, end)
    logger.info("loading %s → %s (%d days) from bucket %s", start, end, len(dates), args.bucket)

    assert_prefixes_exist(args.bucket, dates)

    spark = (
        SparkSession.builder
        .appName(f"gharchive_to_iceberg_{args.start_date}_{args.end_date}")
        .getOrCreate()
    )

    ensure_table(spark, args.bucket)

    paths = build_source_paths(args.bucket, dates)
    source = read_source(spark, paths)

    log_source_counts(logger, source)
    write_partitions(spark, source)
    log_target_counts(logger, spark, start, end)

    logger.info("load complete")
    spark.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
