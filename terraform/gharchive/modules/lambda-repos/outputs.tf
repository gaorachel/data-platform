output "function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.github_repos.arn
}

output "function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.github_repos.function_name
}
