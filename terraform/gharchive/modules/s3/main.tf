# Lifecycle policy scoped to the raw/gharchive/ prefix on the shared main bucket.
#
# Note: aws_s3_bucket_lifecycle_configuration replaces ALL lifecycle rules on the
# bucket when applied. If terraform/shared later adds its own lifecycle rules, they
# should be consolidated here or managed via a single resource to avoid conflicts.

resource "aws_s3_bucket_lifecycle_configuration" "gharchive" {
  bucket = var.bucket_name

  rule {
    id     = "gharchive-raw-tiering"
    status = "Enabled"

    filter {
      prefix = "raw/gharchive/"
    }

    # Raw .json.gz files are queried frequently in the first month (dbt runs, Snowflake)
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # After 90 days, queries are rare — archive to Glacier to reduce storage cost
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}
