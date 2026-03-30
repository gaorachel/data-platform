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
