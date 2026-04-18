output "glue_database_name" {
  description = "Name of the Glue database holding Iceberg table metadata. Used by Spark as the catalog namespace."
  value       = module.glue.database_name
}

output "glue_database_arn" {
  description = "ARN of the Glue database. Useful for cross-account grants or audit."
  value       = module.glue.database_arn
}

output "emr_serverless_application_id" {
  description = "ID of the EMR Serverless application. Passed to StartJobRun as applicationId."
  value       = module.emr_serverless.application_id
}

output "emr_serverless_application_arn" {
  description = "ARN of the EMR Serverless application."
  value       = module.emr_serverless.application_arn
}

output "emr_serverless_execution_role_arn" {
  description = "ARN of the IAM role that EMR Serverless job runs assume. Passed to StartJobRun as executionRoleArn."
  value       = module.emr_serverless.execution_role_arn
}
