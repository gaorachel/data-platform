variable "aws_region" {
  description = "AWS region to deploy gharchive resources in"
  type        = string
  default     = "eu-west-1"
}

variable "s3_bucket_name" {
  description = "Name of the shared general S3 bucket (provisioned by terraform/shared, applied first). Pass the value from terraform/shared outputs — includes the account ID suffix."
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment zip, relative to this directory. Build with 'make build' before applying."
  type        = string
  default     = "../../ingestion/gharchive/lambda.zip"
}

# ── Snowflake credentials (supply via snowflake.tfvars, never hardcode) ───────

variable "snowflake_organization_name" {
  description = "Snowflake organization name (from SELECT CURRENT_ORGANIZATION_NAME()). Used by provider 1.x instead of the legacy account locator."
  type        = string
}

variable "snowflake_account_name" {
  description = "Snowflake account name (from SELECT CURRENT_ACCOUNT_NAME()). Used by provider 1.x instead of the legacy account locator."
  type        = string
}

variable "snowflake_user" {
  description = "Snowflake user that Terraform will authenticate as. Needs SYSADMIN or ACCOUNTADMIN."
  type        = string
}

variable "snowflake_password" {
  description = "Password for snowflake_username. Pass via snowflake.tfvars, never hardcode."
  type        = string
  sensitive   = true
}

variable "snowflake_role" {
  description = "Snowflake role Terraform will use (e.g. ACCOUNTADMIN). Must have CREATE DATABASE, WAREHOUSE, INTEGRATION privileges."
  type        = string
  default     = "ACCOUNTADMIN"
}
