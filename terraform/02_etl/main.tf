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
# S3 — Processed (Parquet) Logs Bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "processed_logs" {
  bucket = "dns-processed-logs-${var.aws_account_id}"

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "etl"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_logs" {
  bucket = aws_s3_bucket.processed_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "processed_logs" {
  bucket = aws_s3_bucket.processed_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — Glue Scripts Bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "glue_scripts" {
  bucket = "dns-glue-scripts-${var.aws_account_id}"

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "etl"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "dns_etl_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/dns_etl.py"
  source = "${path.module}/../../glue/dns_etl.py"
  etag   = filemd5("${path.module}/../../glue/dns_etl.py")
}

# ─────────────────────────────────────────────────────────────────────────────
# Glue Catalog Database
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_glue_catalog_database" "dns_analytics" {
  name = "dns_analytics"
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Glue ETL Role (least privilege)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "glue_etl" {
  name = "glue-dns-etl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project   = "dns-log-pipeline"
    ManagedBy = "terraform"
  }
}

# Glue requires its own service-role policy for CloudWatch Logs & Glue internals
resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_etl.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_data_access" {
  name = "glue-data-access"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRawBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.s3_raw_bucket_name}",
          "arn:aws:s3:::${var.s3_raw_bucket_name}/*"
        ]
      },
      {
        Sid    = "ReadWriteProcessedBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.processed_logs.arn,
          "${aws_s3_bucket.processed_logs.arn}/*"
        ]
      },
      {
        Sid    = "ReadGlueScripts"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.glue_scripts.arn}/*"
      },
      {
        Sid    = "GlueCatalogAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetPartition",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:BatchCreatePartition"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${aws_glue_catalog_database.dns_analytics.name}",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:table/${aws_glue_catalog_database.dns_analytics.name}/*"
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Glue ETL Job
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_glue_job" "dns_daily_etl" {
  name         = "dns-daily-etl"
  role_arn     = aws_iam_role.glue_etl.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/scripts/dns_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--source_bucket"                    = var.s3_raw_bucket_name
    "--target_bucket"                    = aws_s3_bucket.processed_logs.id
    "--job-language"                     = "python"
    "--enable-metrics"                   = ""
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-job-insights"              = "true"
    # Spark UI logs for debugging failed runs
    "--enable-spark-ui"               = "true"
    "--spark-event-logs-path"         = "s3://${aws_s3_bucket.glue_scripts.id}/spark-logs/"
    "--conf"                          = "spark.sql.sources.partitionOverwriteMode=dynamic"
  }

  worker_type       = "G.1X"
  number_of_workers = 5
  max_retries       = 1
  timeout           = 60   # minutes — well above expected 20–30 min runtime

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "etl"
    ManagedBy = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Glue Crawler — Registers new date partitions in the Glue Catalog daily
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_glue_crawler" "dns_processed" {
  name          = "dns-processed-crawler"
  role          = aws_iam_role.glue_etl.arn
  database_name = aws_glue_catalog_database.dns_analytics.name

  # Runs at 06:00 UTC — after the ETL job is expected to complete
  schedule = "cron(0 6 * * ? *)"

  s3_target {
    path = "s3://${aws_s3_bucket.processed_logs.id}/dns_logs/"
  }

  # Only add/update partitions — never delete existing schema
  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "etl"
    ManagedBy = "terraform"
  }
}
