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

# ─────────────────────────────────────────────────────────────────────────────
# S3 — Raw DNS Logs Bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "raw_logs" {
  bucket = "dns-raw-logs-${var.aws_account_id}"

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "ingestion"
    ManagedBy = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "raw_logs" {
  bucket = aws_s3_bucket.raw_logs.id

  versioning_configuration {
    # Versioning disabled — DNS logs are write-once; versioning only inflates
    # storage costs and provides no benefit for immutable event data.
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_logs" {
  bucket = aws_s3_bucket.raw_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "raw_logs" {
  bucket = aws_s3_bucket.raw_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_logs" {
  bucket = aws_s3_bucket.raw_logs.id

  rule {
    id     = "transition-to-glacier-ir-after-30-days"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Firehose Delivery Role (least privilege)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "firehose_delivery" {
  name = "firehose-delivery-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = {
    Project   = "dns-log-pipeline"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_role_policy" "firehose_s3_write" {
  name = "firehose-s3-write-only"
  role = aws_iam_role.firehose_delivery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3PutOnly"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        # Scoped to the exact bucket — no wildcard resource
        Resource = "${aws_s3_bucket.raw_logs.arn}/*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Kinesis Data Firehose — DNS Log Delivery Stream
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "dns_logs" {
  name        = "dns-log-firehose"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_delivery.arn
    bucket_arn = aws_s3_bucket.raw_logs.arn

    # Hive-compatible prefixes enable Athena partition inference downstream
    prefix              = "year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/!{firehose:error-output-type}/"

    # 128 MB or 300 seconds — whichever is reached first.
    # Large files reduce S3 PUT costs and are optimal for Athena's parallel scan.
    buffering_size     = 128
    buffering_interval = 300

    # GZIP cuts storage costs by ~70% with zero query-time overhead for Athena.
    compression_format = "GZIP"
  }

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "ingestion"
    ManagedBy = "terraform"
  }
}
