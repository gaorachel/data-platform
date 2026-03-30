terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Used to make bucket names globally unique by appending the account ID.
data "aws_caller_identity" "current" {}

locals {
  main_bucket_name       = "${var.main_bucket_name}-${data.aws_caller_identity.current.account_id}"
  restricted_bucket_name = "${var.restricted_bucket_name}-${data.aws_caller_identity.current.account_id}"
}

# ── General analytics bucket ──────────────────────────────────────────────────
# Landing zone for public, non-sensitive sources (e.g. gharchive).
# Standard IAM; prefix-scoped per Lambda so sources can't cross-write.

resource "aws_s3_bucket" "main" {
  bucket = local.main_bucket_name

  tags = {
    classification = "general"
    managed_by     = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── KMS key for restricted bucket ─────────────────────────────────────────────

resource "aws_kms_key" "restricted" {
  description             = "Encryption key for the restricted data lake bucket (security logs, PII, PCI)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    classification = "restricted"
    managed_by     = "terraform"
  }
}

resource "aws_kms_alias" "restricted" {
  name          = "alias/data-platform-restricted"
  target_key_id = aws_kms_key.restricted.key_id
}

# ── Restricted bucket ─────────────────────────────────────────────────────────
# For security logs, PII, compliance-sensitive data.
# Separate KMS key, CloudTrail logging enabled, strict IAM.

resource "aws_s3_bucket" "restricted" {
  bucket = local.restricted_bucket_name

  tags = {
    classification = "restricted"
    managed_by     = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "restricted" {
  bucket = aws_s3_bucket.restricted.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "restricted" {
  bucket = aws_s3_bucket.restricted.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.restricted.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "restricted" {
  bucket                  = aws_s3_bucket.restricted.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "restricted" {
  bucket        = aws_s3_bucket.restricted.id
  target_bucket = aws_s3_bucket.main.id
  target_prefix = "access-logs/restricted/"
}
