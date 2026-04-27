variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket the Lambda will write to (passed as S3_BUCKET env var)"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket, used to scope the IAM policy to the raw/github-repos/* prefix"
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment zip package"
  type        = string
}

variable "secret_arns" {
  description = "ARNs of the Secrets Manager secrets the Lambda is allowed to read (GitHub PAT, Snowflake private key)"
  type        = list(string)
}

variable "environment_variables" {
  description = "Map of environment variables to pass to the Lambda function"
  type        = map(string)
  sensitive   = true
}
