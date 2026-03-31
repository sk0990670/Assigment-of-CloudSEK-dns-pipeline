terraform {
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────────────────────────────────────
# SNS — Ops Alerts Topic
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "ops_alerts" {
  name = "dns-pipeline-ops-alerts"
  tags = { Project = "dns-log-pipeline"; ManagedBy = "terraform" }
}

resource "aws_ssm_parameter" "ops_emails" {
  name        = "/dns-pipeline/ops-emails"
  type        = "StringList"
  value       = "devops@example.com"
  description = "Comma-separated ops team emails for pipeline failure alerts."

  lifecycle { ignore_changes = [value] }
}

data "aws_ssm_parameter" "ops_emails" {
  name = aws_ssm_parameter.ops_emails.name
}

# Dynamically subscribe each email from SSM to the SNS topic
resource "aws_sns_topic_subscription" "ops_email" {
  for_each  = toset(split(",", trimspace(data.aws_ssm_parameter.ops_emails.value)))
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = trimspace(each.value)
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Step Functions Execution Role (least privilege)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "step_functions" {
  name = "dns-pipeline-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = "dns-log-pipeline"; ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "step_functions_permissions" {
  name = "sfn-pipeline-permissions"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueJobControl"
        Effect = "Allow"
        Action = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:job/${var.glue_job_name}"
      },
      {
        Sid    = "GlueCrawlerControl"
        Effect = "Allow"
        Action = ["glue:StartCrawler", "glue:GetCrawler"]
        Resource = "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:crawler/${var.glue_crawler_name}"
      },
      {
        Sid      = "InvokeLambda"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = var.lambda_function_arn
      },
      {
        Sid      = "PublishSNS"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.ops_alerts.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Step Functions — State Machine (Amazon States Language)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sfn_state_machine" "dns_daily_pipeline" {
  name     = "dns-daily-pipeline"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "DNS Log Pipeline — daily ETL → Catalog → Report orchestration"
    StartAt = "StartGlueETL"

    States = {

      # ── Step 1: Start the Glue ETL job ────────────────────────────────────
      # .sync:2 integration waits for the job to complete before advancing.
      StartGlueETL = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync:2"
        Parameters = {
          JobName = var.glue_job_name
        }
        Next = "StartGlueCrawler"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
          ResultPath  = "$.errorInfo"
        }]
      }

      # ── Step 2: Trigger the Glue Crawler ──────────────────────────────────
      StartGlueCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = var.glue_crawler_name
        }
        Next = "WaitForCrawler"
        Catch = [{
          ErrorEquals = ["Glue.CrawlerRunningException"]
          # Crawler already running — safe to skip to the wait/poll loop
          Next       = "WaitForCrawler"
          ResultPath = "$.crawlerRunningError"
        }, {
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
          ResultPath  = "$.errorInfo"
        }]
      }

      # ── Step 3: Poll crawler status (no native .sync integration) ─────────
      WaitForCrawler = {
        Type    = "Wait"
        Seconds = 30
        Next    = "CheckCrawlerStatus"
      }

      CheckCrawlerStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = {
          Name = var.glue_crawler_name
        }
        Next = "IsCrawlerDone"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
          ResultPath  = "$.errorInfo"
        }]
      }

      IsCrawlerDone = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.Crawler.State"
            StringEquals  = "READY"
            Next          = "InvokeReportLambda"
          },
          {
            Variable      = "$.Crawler.State"
            StringEquals  = "RUNNING"
            Next          = "WaitForCrawler"
          },
          {
            Variable      = "$.Crawler.State"
            StringEquals  = "STOPPING"
            Next          = "WaitForCrawler"
          }
        ]
        # Unexpected state — treat as failure
        Default = "NotifyFailure"
      }

      # ── Step 4: Invoke report generator Lambda ────────────────────────────
      InvokeReportLambda = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName     = var.lambda_function_arn
          InvocationType   = "RequestResponse"
          "Payload.$"      = "$"
        }
        Next = "PipelineSucceeded"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
          ResultPath  = "$.errorInfo"
        }]
      }

      PipelineSucceeded = {
        Type = "Succeed"
      }

      # ── Failure handler: publish alert to SNS ─────────────────────────────
      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn       = aws_sns_topic.ops_alerts.arn
          "Subject"      = "🚨 DNS Pipeline FAILED"
          "Message.$"   = "States.Format('DNS pipeline execution failed.\\nExecution: {}\\nError: {}', $$.Execution.Name, States.JsonToString($.errorInfo))"
        }
        Next = "PipelineFailed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineExecutionFailed"
        Cause = "One or more pipeline stages failed. Check CloudWatch Logs for details."
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = { Project = "dns-log-pipeline"; Layer = "orchestration"; ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/dns-daily-pipeline"
  retention_in_days = 14
}

# ─────────────────────────────────────────────────────────────────────────────
# EventBridge Scheduler — Single daily trigger for the state machine
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "scheduler" {
  name = "dns-pipeline-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_start_sfn" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.dns_daily_pipeline.arn
    }]
  })
}

resource "aws_scheduler_schedule" "daily_pipeline" {
  name = "dns-pipeline-daily-trigger"

  flexible_time_window { mode = "OFF" }

  # 05:00 UTC — enough lead time after the midnight spike window flushes
  schedule_expression = "cron(0 5 * * ? *)"

  target {
    arn      = aws_sfn_state_machine.dns_daily_pipeline.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({})
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudWatch Alarms
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "dns-report-generator-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.lambda_function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "Report Lambda threw an error — check CloudWatch Logs."
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "firehose_delivery_lag" {
  alarm_name          = "dns-firehose-delivery-lag"
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.DataFreshness"
  dimensions          = { DeliveryStreamName = "dns-log-firehose" }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 900   # 15 minutes — records backing up
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "Firehose is not flushing to S3. Records may be at risk."
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  treat_missing_data  = "notBreaching"
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS Budgets — Hard monthly spend cap
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_budgets_budget" "pipeline_monthly" {
  name         = "dns-pipeline-monthly-budget"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = "800"
  limit_unit   = "USD"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$dns-log-pipeline"]
  }

  # Alert at $700 actual spend — gives $100 buffer to investigate before hitting limit
  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 87.5   # 87.5% of $800 = $700
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [split(",", trimspace(data.aws_ssm_parameter.ops_emails.value))[0]]
  }

  # Alert when forecasted spend is on track to exceed $800
  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [split(",", trimspace(data.aws_ssm_parameter.ops_emails.value))[0]]
  }
}

# =============================================================================
# ESTIMATED MONTHLY COST BREAKDOWN
# =============================================================================
# Kinesis Firehose:    ~$113/mo  (3,900 GB ingested @ $0.029/GB)
# S3 raw storage:      ~$90/mo   (first 30 days; drops ~80% after Glacier IR transition)
# Glue ETL job:        ~$66/mo   (5 x G.1X workers, ~30 min/day x 30 days)
# Glue Crawler:        ~$1/mo
# Athena queries:      ~$1/mo    (Parquet + partition pruning = <200MB scanned/day)
# Lambda:              ~$0/mo    (1 invocation/day — well within free tier)
# CloudFront:          ~$5/mo    (PriceClass_100 — US + Europe)
# SES:                 ~$0/mo    (<1,000 emails/month)
# Step Functions:      ~$0/mo    (~10 transitions/day)
# CloudWatch + SNS:    ~$3/mo
# ------------------------------------
# TOTAL ESTIMATE:      ~$279–$350/mo
# Budget headroom:     ~$450–$520/mo (well inside $800 limit)
# =============================================================================
