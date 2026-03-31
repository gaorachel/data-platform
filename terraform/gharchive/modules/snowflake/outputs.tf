output "storage_aws_iam_user_arn" {
  description = "ARN of the Snowflake-managed IAM user that will assume the customer IAM role. Use this to update the aws_iam_role.snowflake_integration trust policy."
  value       = snowflake_storage_integration.s3.storage_aws_iam_user_arn
}

output "storage_aws_external_id" {
  description = "External ID that Snowflake passes when assuming the customer IAM role. Add this as a StringEquals condition in the trust policy."
  value       = snowflake_storage_integration.s3.storage_aws_external_id
}

# notification_channel is not an exported attribute of snowflake_external_table
# in provider 1.x (it was removed during the 0.x → 1.x resource redesign).
# To retrieve the Snowflake-managed SQS queue ARN after apply, run:
#
#   SHOW EXTERNAL TABLES LIKE 'GHARCHIVE_EVENTS' IN SCHEMA DATA_PLATFORM.GHARCHIVE;
#
# The notification_channel column in that result contains the ARN to use
# when configuring the second S3 event notification rule for AUTO_REFRESH.
