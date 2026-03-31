variable "queue_name" {
  description = "Name of the SQS queue that buffers S3 event notifications"
  type        = string
  default     = "gharchive-s3-events"
}
