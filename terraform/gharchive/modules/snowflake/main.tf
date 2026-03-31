terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 1.0"
    }
  }
}

resource "snowflake_database" "data_platform" {
  name = "DATA_PLATFORM"
}

resource "snowflake_schema" "gharchive" {
  database = snowflake_database.data_platform.name
  name     = "GHARCHIVE"
}

resource "snowflake_warehouse" "compute_wh" {
  name           = "COMPUTE_WH"
  warehouse_size = "XSMALL"
  auto_suspend   = 60
  auto_resume    = true
}

# ── Storage integration ───────────────────────────────────────────────────────
# Snowflake assumes storage_aws_role_arn to access S3. That IAM role is
# provisioned by the root module with a placeholder Deny trust policy.
#
# After apply:
#   1. Get snowflake_storage_integration_iam_user_arn and
#      snowflake_storage_integration_external_id from terraform output.
#   2. Update the aws_iam_role.snowflake_integration assume_role_policy in
#      main.tf with an Allow statement trusting those values.
#   3. Run terraform apply again to push the trust policy change.

resource "snowflake_storage_integration" "s3" {
  name    = "GHARCHIVE_S3_INTEGRATION"
  type    = "EXTERNAL_STAGE"
  enabled = true

  storage_provider     = "S3"
  storage_aws_role_arn = var.storage_aws_role_arn

  storage_allowed_locations = [
    "s3://${var.s3_bucket_name}/raw/gharchive/"
  ]
}

# ── External stage ────────────────────────────────────────────────────────────
resource "snowflake_stage" "gharchive" {
  database = snowflake_database.data_platform.name
  schema   = snowflake_schema.gharchive.name
  name     = "GHARCHIVE_S3_STAGE"

  url                 = "s3://${var.s3_bucket_name}/raw/gharchive/"
  storage_integration = snowflake_storage_integration.s3.name
}

# ── External table ────────────────────────────────────────────────────────────
# snowflake_external_table is NOT managed by Terraform.
# The snowflake provider v1.x has a bug where it cannot create external tables
# with AUTO_REFRESH = TRUE. Run snowflake/setup.sql manually once after apply.
