terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
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
