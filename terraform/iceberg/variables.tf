variable "aws_region" {
  description = "AWS region for iceberg resources. Must match the region of the shared S3 bucket and the Glue catalog."
  type        = string
  default     = "eu-west-1"
}

variable "s3_bucket_name" {
  description = "Name of the shared general S3 bucket (provisioned by terraform/shared, applied first). Pass the value from terraform/shared outputs — includes the account ID suffix."
  type        = string
}

variable "glue_database_name" {
  description = "Name of the Glue Data Catalog database that holds Iceberg table metadata. Tables inside are created by the Spark writer via CREATE TABLE IF NOT EXISTS, not Terraform."
  type        = string
  default     = "gharchive_iceberg"
}

variable "emr_release_label" {
  description = "EMR release label for the Serverless application. emr-7.12.0 is the latest stable release and ships with Iceberg 1.10 natively (no jar upload required)."
  type        = string
  default     = "emr-7.12.0"
}
