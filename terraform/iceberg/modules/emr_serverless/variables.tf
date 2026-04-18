variable "application_name" {
  description = "Name of the EMR Serverless application. Also used as a prefix for the execution role name."
  type        = string
}

variable "release_label" {
  description = "EMR release label. Pick one where Iceberg ships natively so jobs don't need a jar upload step."
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the shared general S3 bucket, used to scope bucket-level IAM actions (ListBucket, GetBucketLocation)."
  type        = string
}

variable "raw_prefix" {
  description = "S3 prefix holding raw gharchive hourly files. The execution role gets read-only access under this prefix."
  type        = string
}

variable "iceberg_prefix" {
  description = "S3 prefix holding Iceberg table data and metadata. The execution role gets read-write access under this prefix."
  type        = string
}

variable "glue_database_name" {
  description = "Glue database the execution role is allowed to read and write. All other databases remain inaccessible."
  type        = string
}

variable "aws_region" {
  description = "AWS region — needed to build Glue and CloudWatch Logs ARNs."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID — needed to build Glue and CloudWatch Logs ARNs."
  type        = string
}
