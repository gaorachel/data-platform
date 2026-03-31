output "queue_arn" {
  description = "ARN of the SQS queue that buffers S3 event notifications"
  value       = aws_sqs_queue.gharchive_events.arn
}

output "queue_url" {
  description = "URL of the SQS queue (used in queue policy resource)"
  value       = aws_sqs_queue.gharchive_events.url
}
