variable "aws_region" {
  description = "AWS region to deploy shared infrastructure in"
  type        = string
  default     = "eu-west-1"
}

variable "main_bucket_name" {
  description = "Name of the general-classification S3 data lake bucket (public data, non-sensitive analytics sources)"
  type        = string
  default     = "data-platform-main"
}

variable "restricted_bucket_name" {
  description = "Name of the restricted-classification S3 data lake bucket (security logs, PII, PCI data)"
  type        = string
  default     = "data-platform-restricted"
}
