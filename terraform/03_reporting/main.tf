terraform {
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — Reports Bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "reports" {
  bucket = "dns-reports-${var.aws_account_id}"

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "reporting"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_cors_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Athena Workgroup
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_athena_workgroup" "dns_analytics" {
  name = "dns-analytics-wg"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.reports.id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Safety cutoff — a misconfigured query cannot scan more than 10 GB.
    # Normal daily queries scan well under 200 MB with Parquet + partitioning.
    bytes_scanned_cutoff_per_query = 10737418240
  }

  tags = {
    Project   = "dns-log-pipeline"
    ManagedBy = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Lambda Execution Role
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "report_lambda" {
  name = "dns-report-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = "dns-log-pipeline"; ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.report_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_lambda_permissions" {
  name = "report-lambda-data-access"
  role = aws_iam_role.report_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution"
        ]
        Resource = aws_athena_workgroup.dns_analytics.arn
      },
      {
        Sid      = "AthenaResultsWrite"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation"]
        Resource = [
          "${aws_s3_bucket.reports.arn}/athena-results/*",
          aws_s3_bucket.reports.arn
        ]
      },
      {
        Sid    = "ReadProcessedData"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.processed_s3_bucket_arn,
          "${var.processed_s3_bucket_arn}/*"
        ]
      },
      {
        Sid    = "WriteReports"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = ["glue:GetTable", "glue:GetDatabase", "glue:GetPartitions"]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:table/${var.glue_database_name}/*"
        ]
      },
      {
        Sid    = "SSMRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/dns-pipeline/*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda Function
# ─────────────────────────────────────────────────────────────────────────────

# The zip must be built via Docker per README_packaging.md in the lambda dir.
# Terraform expects the file at this path before applying.
data "archive_file" "report_lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda_placeholder.zip"

  source {
    content  = "# placeholder — replace with docker-built package"
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "report_generator" {
  function_name = "dns-report-generator"
  role          = aws_iam_role.report_lambda.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 300
  memory_size   = 1024

  # Replace this with the real built zip after running the Docker packaging steps
  filename         = data.archive_file.report_lambda_placeholder.output_path
  source_code_hash = data.archive_file.report_lambda_placeholder.output_base64sha256

  environment {
    variables = {
      REPORTS_BUCKET       = aws_s3_bucket.reports.id
      ATHENA_DATABASE      = var.glue_database_name
      ATHENA_WORKGROUP     = aws_athena_workgroup.dns_analytics.name
      # CLOUDFRONT_DOMAIN, SENDER_EMAIL, RECIPIENTS_SSM_PARAM added in layer 04
    }
  }

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "reporting"
    ManagedBy = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EventBridge Scheduler (temporary — replaced by Step Functions in layer 05)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "scheduler_invoke_lambda" {
  name = "dns-scheduler-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke_lambda" {
  role = aws_iam_role.scheduler_invoke_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.report_generator.arn
    }]
  })
}

resource "aws_scheduler_schedule" "daily_report" {
  name = "dns-report-daily-trigger"

  flexible_time_window { mode = "OFF" }

  # 07:00 UTC — after ETL (05:00) + Crawler (06:00) complete
  schedule_expression = "cron(0 7 * * ? *)"

  target {
    arn      = aws_lambda_function.report_generator.arn
    role_arn = aws_iam_role.scheduler_invoke_lambda.arn
    input    = jsonencode({})
  }
}
