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

# ── S3 event notification ─────────────────────────────────────────────────────
# aws_s3_bucket_notification is a singleton per bucket — only one resource
# can manage all notification targets. This replaces any manually configured
# notifications on the bucket.
#
# Routes object-created events for .json.gz files under raw/gharchive/ directly
# to Snowflake's managed SQS queue for AUTO_REFRESH.

# ── Locals ────────────────────────────────────────────────────────────────────
# Snowflake account identifier expected by snowflake-connector-python:
# orgname-accountname (e.g. "myorg-myaccount")

locals {
  snowflake_account = "${var.snowflake_organization_name}-${var.snowflake_account_name}"
}

# ── Secrets Manager: GitHub PAT ───────────────────────────────────────────────
# Stores the GitHub Personal Access Token used by the repo-enrichment Lambda.
# The placeholder value is written on first apply; replace it manually:
#   aws secretsmanager put-secret-value \
#     --secret-id data-platform/github/pat \
#     --secret-string '{"token":"ghp_..."}'
# The lifecycle block prevents Terraform from overwriting a real token on
# subsequent applies.

resource "aws_secretsmanager_secret" "github_pat" {
  name        = "data-platform/github/pat"
  description = "GitHub PAT for repo metadata enrichment"
}

resource "aws_secretsmanager_secret_version" "github_pat" {
  secret_id     = aws_secretsmanager_secret.github_pat.id
  secret_string = jsonencode({ token = "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── Snowflake IAM: extend to raw/github-repos/* ───────────────────────────────
# The existing snowflake_s3_read policy covers raw/gharchive/* only.
# This separate policy grants read on the new prefix without modifying the
# existing policy. Both policies attach to the same role.

resource "aws_iam_role_policy" "snowflake_s3_read_github_repos" {
  name = "snowflake-s3-read-github-repos"
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
        "${data.aws_s3_bucket.main.arn}/raw/github-repos/*"
      ]
    }]
  })
}

# ── Lambda: github-repo-enrichment ───────────────────────────────────────────

module "lambda_github_repos" {
  source = "./modules/lambda-repos"

  function_name   = "github-repo-enrichment"
  s3_bucket_name  = data.aws_s3_bucket.main.bucket
  s3_bucket_arn   = data.aws_s3_bucket.main.arn
  lambda_zip_path = var.lambda_repos_zip_path
  secret_arn      = aws_secretsmanager_secret.github_pat.arn

  environment_variables = {
    S3_BUCKET           = data.aws_s3_bucket.main.bucket
    SECRET_NAME         = aws_secretsmanager_secret.github_pat.name
    SNOWFLAKE_ACCOUNT   = local.snowflake_account
    SNOWFLAKE_USER      = var.snowflake_user
    SNOWFLAKE_PASSWORD  = var.snowflake_password
    SNOWFLAKE_DATABASE  = "DATA_PLATFORM"
    SNOWFLAKE_SCHEMA    = "GHARCHIVE"
    SNOWFLAKE_WAREHOUSE = "COMPUTE_WH"
    TOP_N_REPOS         = "100"
  }
}

# ── EventBridge: weekly repo enrichment ───────────────────────────────────────
# Runs Sundays at 02:00 UTC — quiet period, avoids GitHub API peak hours.

resource "aws_cloudwatch_event_rule" "github_repos_weekly" {
  name                = "github-repo-enrichment-schedule"
  description         = "Triggers the github-repo-enrichment Lambda weekly on Sundays at 02:00 UTC"
  schedule_expression = "cron(0 2 ? * SUN *)"
}

resource "aws_cloudwatch_event_target" "github_repos_lambda" {
  rule      = aws_cloudwatch_event_rule.github_repos_weekly.name
  target_id = "github-repo-enrichment"
  arn       = module.lambda_github_repos.function_arn
}

resource "aws_lambda_permission" "allow_eventbridge_github_repos" {
  statement_id  = "AllowEventBridgeInvokeGithubRepos"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_github_repos.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.github_repos_weekly.arn
}

resource "aws_s3_bucket_notification" "gharchive_events" {
  bucket = data.aws_s3_bucket.main.id

  queue {
    id            = "gharchive-to-snowflake-sqs"
    queue_arn     = var.snowflake_notification_channel_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/gharchive/"
    filter_suffix = ".json.gz"
  }
}
