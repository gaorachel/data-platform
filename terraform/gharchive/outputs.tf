output "lambda_function_name" {
  description = "Name of the deployed gharchive Lambda function"
  value       = module.lambda.function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed gharchive Lambda function"
  value       = module.lambda.function_arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule that triggers the Lambda"
  value       = aws_cloudwatch_event_rule.gharchive_hourly.name
}

# ── Snowflake storage integration — needed to wire up the IAM trust policy ───

output "snowflake_storage_integration_iam_user_arn" {
  description = "ARN of the Snowflake-managed IAM user that assumes the gharchive-snowflake-integration role. Use this as the Principal in the aws_iam_role trust policy, then re-apply."
  value       = module.snowflake.storage_aws_iam_user_arn
}

output "snowflake_storage_integration_external_id" {
  description = "External ID that Snowflake passes on sts:AssumeRole. Use this as a StringEquals condition on sts:ExternalId in the trust policy, then re-apply."
  value       = module.snowflake.storage_aws_external_id
}

