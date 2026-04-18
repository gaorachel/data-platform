# ── Execution role ───────────────────────────────────────────────────────────
# Assumed by EMR Serverless job runs. Scoped so the Spark driver/executors
# can read raw gharchive files, read+write iceberg table data, and read+write
# the one Glue database. No access to the restricted bucket, no access to
# other Glue databases, no general logs:* wildcard.

resource "aws_iam_role" "execution" {
  name        = "${var.application_name}-emr-exec-role"
  description = "Assumed by EMR Serverless job runs for the ${var.application_name} application. Scoped to the gharchive iceberg table location and the ${var.glue_database_name} Glue database."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "emr-serverless.amazonaws.com" }
    }]
  })
}

# Read-only on the raw gharchive prefix. The Spark job reads hourly .json.gz
# files written by the ingestion Lambda.
resource "aws_iam_role_policy" "s3_read_raw" {
  name = "s3-read-raw-gharchive"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${var.s3_bucket_arn}/${var.raw_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = var.s3_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["${var.raw_prefix}/*", "${var.raw_prefix}", "${var.iceberg_prefix}/*", "${var.iceberg_prefix}"]
          }
        }
      }
    ]
  })
}

# Read + write on the iceberg table location. Covers data files, metadata
# files, and the manifests/snapshots Iceberg needs to rewrite during commits,
# compaction, and snapshot expiration.
resource "aws_iam_role_policy" "s3_rw_iceberg" {
  name = "s3-rw-iceberg-gharchive"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ]
      Resource = "${var.s3_bucket_arn}/${var.iceberg_prefix}/*"
    }]
  })
}

# Glue catalog access, scoped to the one database and its tables.
# Table actions use a wildcard because tables are created by Spark at runtime
# and we don't know their names at apply time — but the wildcard is scoped
# to tables under this database only.
resource "aws_iam_role_policy" "glue_catalog" {
  name = "glue-catalog-${var.glue_database_name}"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${var.glue_database_name}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:CreateTable",
          "glue:GetTable",
          "glue:GetTables",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:BatchGetPartition",
          "glue:CreatePartition",
          "glue:DeletePartition",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:UpdatePartition"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:table/${var.glue_database_name}/*"
        ]
      }
    ]
  })
}

# CloudWatch Logs for Spark driver + executor output. Scoped to the EMR
# Serverless log group prefix — not a global logs:* grant.
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups"
      ]
      Resource = [
        "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/emr-serverless/*",
        "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/emr-serverless/*:log-stream:*"
      ]
    }]
  })
}

# ── EMR Serverless application ───────────────────────────────────────────────
# Pay-per-use configuration for a learning project:
#   - ARM64 (Graviton) workers — ~20% cheaper than x86 for Spark.
#   - No pre-initialized capacity — workers spin up per job.
#   - Auto-stop after 15 min idle so the application doesn't sit warm overnight.
#   - Maximum capacity caps the blast radius of a runaway job at a few £ per hour.

resource "aws_emrserverless_application" "this" {
  name          = var.application_name
  release_label = var.release_label
  type          = "spark"
  architecture  = "ARM64"

  maximum_capacity {
    cpu    = "4 vCPU"
    memory = "16 GB"
    disk   = "50 GB"
  }

  auto_start_configuration {
    enabled = true
  }

  auto_stop_configuration {
    enabled              = true
    idle_timeout_minutes = 15
  }
}
