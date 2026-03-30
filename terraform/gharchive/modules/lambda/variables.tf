variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket the Lambda will write to (passed as S3_BUCKET env var)"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket, used to scope the IAM policy to the raw/gharchive/* prefix"
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment zip package"
  type        = string
}
