variable "s3_bucket_name" {
  description = "Name of the S3 bucket that holds raw gharchive data (e.g. data-platform-main-074308311757)"
  type        = string
}

variable "storage_aws_role_arn" {
  description = "ARN of the AWS IAM role that Snowflake will assume to read from S3. Created by the root module; trust policy is a placeholder until the first apply outputs the Snowflake IAM user ARN."
  type        = string
}
