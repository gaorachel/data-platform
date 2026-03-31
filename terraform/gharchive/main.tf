terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "snowflake" {
  organization_name        = var.snowflake_organization_name
  account_name             = var.snowflake_account_name
  user                     = var.snowflake_user
  password                 = var.snowflake_password
  role                     = var.snowflake_role
  preview_features_enabled = ["snowflake_storage_integration_resource", "snowflake_stage_resource", "snowflake_external_table_resource"]
}

# Look up the shared bucket by name — avoids coupling this state to terraform/shared's state.
# terraform/shared must be applied first so this bucket already exists.
data "aws_s3_bucket" "main" {
  bucket = var.s3_bucket_name
}

module "lambda" {
  source = "./modules/lambda"

  function_name   = "gharchive-ingestion"
  s3_bucket_name  = data.aws_s3_bucket.main.bucket
  s3_bucket_arn   = data.aws_s3_bucket.main.arn
  lambda_zip_path = var.lambda_zip_path
}

module "s3" {
  source = "./modules/s3"

  bucket_name = data.aws_s3_bucket.main.bucket
}

# ── EventBridge ───────────────────────────────────────────────────────────────
# GitHub Archive publishes the previous hour's file a few minutes after the
# hour. Firing at :05 gives it time to appear before Lambda runs.

resource "aws_cloudwatch_event_rule" "gharchive_hourly" {
  name                = "gharchive-hourly-trigger"
  description         = "Triggers the gharchive ingestion Lambda at 5 past every hour"
  schedule_expression = "cron(5 * * * ? *)"
}

resource "aws_cloudwatch_event_target" "gharchive_lambda" {
  rule      = aws_cloudwatch_event_rule.gharchive_hourly.name
  target_id = "gharchive-lambda"
  arn       = module.lambda.function_arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.gharchive_hourly.arn
}

# ── SQS ───────────────────────────────────────────────────────────────────────

module "sqs" {
  source = "./modules/sqs"
}

# ── Snowflake IAM role ────────────────────────────────────────────────────────
# This role is assumed by the Snowflake storage integration to read from S3.
#
# The assume_role_policy below is a PLACEHOLDER (Effect = Deny) and must be
# updated after the first apply:
#
#   1. Run: terraform output snowflake_storage_integration_iam_user_arn
#           terraform output snowflake_storage_integration_external_id
#   2. Replace the assume_role_policy below with:
#
#      {
#        "Version": "2012-10-17",
#        "Statement": [{
#          "Effect": "Allow",
#          "Principal": { "AWS": "<storage_integration_iam_user_arn>" },
#          "Action": "sts:AssumeRole",
#          "Condition": {
#            "StringEquals": { "sts:ExternalId": "<storage_integration_external_id>" }
#          }
#        }]
#      }
#
#   3. Run: terraform apply -var-file="snowflake.tfvars" ...

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "snowflake_integration" {
  name        = "gharchive-snowflake-integration"
  description = "Assumed by Snowflake storage integration to read gharchive data from S3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::779060063003:user/l5mh1000-s" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = "EG10662_SFCRole=2_5h1m166p8Ghvav3F4qGKG0cNz0w=" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "snowflake_s3_read" {
  name = "snowflake-s3-read"
  role = aws_iam_role.snowflake_integration.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = [
        data.aws_s3_bucket.main.arn,
        "${data.aws_s3_bucket.main.arn}/raw/gharchive/*"
      ]
    }]
  })
}

# ── Snowflake ─────────────────────────────────────────────────────────────────

module "snowflake" {
  source = "./modules/snowflake"

  s3_bucket_name       = data.aws_s3_bucket.main.bucket
  storage_aws_role_arn = aws_iam_role.snowflake_integration.arn
}

# ── SQS queue policy ──────────────────────────────────────────────────────────
# Single policy document combining S3 publish and Snowflake consume grants.
# Lives here (not in the SQS module) so it can reference both module outputs
# without creating a circular dependency.

resource "aws_sqs_queue_policy" "gharchive_events" {
  queue_url = module.sqs.queue_url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3Publish"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = module.sqs.queue_arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = data.aws_s3_bucket.main.arn
          }
        }
      },
      {
        Sid    = "AllowSnowflakeConsume"
        Effect = "Allow"
        Principal = {
          AWS = module.snowflake.storage_aws_iam_user_arn
        }
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage"
        ]
        Resource = module.sqs.queue_arn
      }
    ]
  })
}

# ── S3 event notification ─────────────────────────────────────────────────────
# aws_s3_bucket_notification is a singleton per bucket — only one resource
# can manage all notification targets. This replaces any manually configured
# notifications on the bucket.
#
# Sends object-created events for .json.gz files under raw/gharchive/ to the
# customer-managed SQS queue above. Snowflake's AUTO_REFRESH also needs S3
# events: after apply, retrieve module.snowflake.notification_channel (the
# Snowflake-managed SQS ARN) and add a second queue block here, then re-apply.

resource "aws_s3_bucket_notification" "gharchive_events" {
  bucket     = data.aws_s3_bucket.main.id
  depends_on = [aws_sqs_queue_policy.gharchive_events]

  queue {
    id            = "gharchive-to-customer-sqs"
    queue_arn     = module.sqs.queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/gharchive/"
    filter_suffix = ".json.gz"
  }
}
