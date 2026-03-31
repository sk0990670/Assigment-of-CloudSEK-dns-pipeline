terraform {
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudFront — Origin Access Control
# ─────────────────────────────────────────────────────────────────────────────
# We do NOT use pre-signed URLs. Pre-signed URLs created from IAM Role
# credentials expire when the role session expires (max 12–36 hours),
# regardless of the ExpiresIn value. CloudFront URLs are permanent.

resource "aws_cloudfront_origin_access_control" "reports" {
  name                              = "dns-reports-oac"
  description                       = "OAC for private S3 reports bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudFront Distribution
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "reports" {
  enabled             = true
  comment             = "DNS daily reports distribution"
  default_root_object = ""

  origin {
    domain_name              = "${var.reports_bucket_name}.s3.${var.aws_region}.amazonaws.com"
    origin_id                = "dns-reports-s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.reports.id
  }

  default_cache_behavior {
    target_origin_id       = "dns-reports-s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400    # 1 day
    max_ttl     = 31536000 # 1 year
  }

  # US + Europe only — significantly cheaper than PriceClass_All
  # and sufficient for the expected audience
  price_class = "PriceClass_100"

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Project   = "dns-log-pipeline"
    Layer     = "delivery"
    ManagedBy = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 Bucket Policy — CloudFront-only access (bucket stays private)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket_policy" "reports_cloudfront_only" {
  bucket = var.reports_bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudFrontReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${var.reports_bucket_arn}/reports/*"
        Condition = {
          StringEquals = {
            # Scope to THIS distribution only — not any CloudFront distribution
            "AWS:SourceArn" = aws_cloudfront_distribution.reports.arn
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# SES — Domain Identity
# ─────────────────────────────────────────────────────────────────────────────
# IMPORTANT: After applying this Terraform, you must verify the domain by
# adding the TXT record shown in the AWS console (or via aws_ses_domain_dkim)
# to your DNS provider. Emails will not send until verification is complete.

resource "aws_ses_domain_identity" "sender" {
  domain = var.sender_domain
}

resource "aws_ses_configuration_set" "dns_reports" {
  name = "dns-reports-config"

  reputation_metrics_enabled = true
  sending_enabled            = true
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Grant Lambda SES send permissions
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_ses_send" {
  name = "lambda-ses-send"
  role = var.lambda_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SESSendEmail"
        Effect = "Allow"
        Action = ["ses:SendEmail", "ses:SendRawEmail"]
        # Scoped to the specific verified identity only
        Resource = aws_ses_domain_identity.sender.arn
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# SSM — Recipient email list
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "report_recipients" {
  name  = "/dns-pipeline/report-recipients"
  type  = "StringList"
  # Default placeholder — update via console or CLI before first run
  value = "ops@example.com"

  description = "Comma-separated list of email addresses to receive daily DNS reports."

  tags = { Project = "dns-log-pipeline"; ManagedBy = "terraform" }

  # Prevent Terraform from reverting manually-updated recipient lists on re-apply
  lifecycle {
    ignore_changes = [value]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda — Update environment variables with CloudFront domain + SES config
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lambda_function_event_invoke_config" "report_generator" {
  function_name          = var.lambda_function_arn
  maximum_retry_attempts = 0
}

# We update the Lambda env vars using a separate aws_lambda_function resource
# update is handled by injecting these outputs into layer 03 on a re-apply.
# The outputs below are consumed by layer 05 orchestration.
