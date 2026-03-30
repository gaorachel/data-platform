output "main_bucket_name" {
  description = "Name of the general-classification S3 bucket"
  value       = aws_s3_bucket.main.bucket
}

output "main_bucket_arn" {
  description = "ARN of the general-classification S3 bucket"
  value       = aws_s3_bucket.main.arn
}

output "restricted_bucket_name" {
  description = "Name of the restricted-classification S3 bucket"
  value       = aws_s3_bucket.restricted.bucket
}

output "restricted_bucket_arn" {
  description = "ARN of the restricted-classification S3 bucket"
  value       = aws_s3_bucket.restricted.arn
}

output "restricted_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the restricted bucket"
  value       = aws_kms_key.restricted.arn
}
