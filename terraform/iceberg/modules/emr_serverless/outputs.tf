output "application_id" {
  description = "ID of the EMR Serverless application."
  value       = aws_emrserverless_application.this.id
}

output "application_arn" {
  description = "ARN of the EMR Serverless application."
  value       = aws_emrserverless_application.this.arn
}

output "execution_role_arn" {
  description = "ARN of the IAM role that job runs assume."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Name of the IAM role that job runs assume."
  value       = aws_iam_role.execution.name
}
