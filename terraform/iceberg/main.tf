terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "data-platform-tf-state-074308311757"
    key            = "iceberg/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "data-platform-tf-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project    = "iceberg"
      managed_by = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Look up the shared bucket by name — avoids coupling this state to terraform/shared's state.
# terraform/shared must be applied first so this bucket already exists.
data "aws_s3_bucket" "main" {
  bucket = var.s3_bucket_name
}

# ── Glue Data Catalog database ────────────────────────────────────────────────
# Holds Iceberg table metadata (schema, snapshots, partition spec evolution).
# The Spark job creates tables inside this database via CREATE TABLE IF NOT EXISTS —
# no tables are provisioned by Terraform.

module "glue" {
  source = "./modules/glue"

  database_name = var.glue_database_name
}

# ── EMR Serverless execution: IAM role + application ─────────────────────────
# Single module so the IAM role and the application stay colocated. The role
# is passed to job runs at submit time as executionRoleArn.

module "emr_serverless" {
  source = "./modules/emr_serverless"

  application_name   = "gharchive-iceberg"
  release_label      = var.emr_release_label
  s3_bucket_arn      = data.aws_s3_bucket.main.arn
  raw_prefix         = "raw/gharchive"
  iceberg_prefix     = "iceberg/gharchive"
  glue_database_name = module.glue.database_name
  aws_region         = var.aws_region
  aws_account_id     = data.aws_caller_identity.current.account_id
}
