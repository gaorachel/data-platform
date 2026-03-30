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
