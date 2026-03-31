resource "aws_sqs_queue" "gharchive_events" {
  name = var.queue_name

  # S3 event notifications are small; 1-day retention is enough for replay.
  message_retention_seconds  = 86400
  # Lambda or Snowflake consumers should finish within 30s; otherwise the
  # message becomes visible again for reprocessing.
  visibility_timeout_seconds = 30

  tags = {
    Project = "gharchive"
    Purpose = "Buffer S3 event notifications for Snowflake AUTO_REFRESH"
  }
}
