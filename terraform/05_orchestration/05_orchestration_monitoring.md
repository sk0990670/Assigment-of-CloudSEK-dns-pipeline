# 05 — Orchestration, Monitoring & Budget Guard

### Rationale

At this point we have four separate timed jobs: Firehose buffers continuously, the Glue ETL job runs nightly, the Crawler runs after that, and the Lambda report generator runs after that. If we just drop independent cron triggers on each one, we've created a fragile mess. The ETL job might fail, but the Crawler runs on time anyway — on yesterday's stale data. The report Lambda fires and produces garbage. Nobody finds out until the wrong numbers are already in an email.

The fix is **Step Functions**. It chains the three discrete jobs (ETL → Crawler → Lambda) into a sequential state machine with explicit success/failure transitions. If anything fails, the whole pipeline stops and fires an SNS alert. Step Functions Standard Workflow charges per state transition — our daily pipeline makes roughly 10 transitions, which costs a fraction of a cent per month. It's genuinely free at this scale.

A single EventBridge Scheduler rule kicks off the state machine at 05:00 UTC. I chose 05:00 UTC deliberately — it gives Firehose enough time to flush the final records from the 10-minute spike window (which happens around midnight for most US-based traffic patterns) before we start processing. The Lambda report generator used to have its own EventBridge trigger from Step 03; we're removing that here since Step Functions now drives it.

The last thing I want is to wake up to a surprise AWS bill. So we're adding a CloudWatch Budget alert that fires an SNS notification at $700 actual spend (before we hit the $800 wall) and another at $800 forecasted. These take 5 minutes to set up in Terraform and have saved me from disasters more than once.

---

### Prompt

**Role:** You're a DevOps engineer who treats operational reliability and cost control as first-class requirements, not afterthoughts.

**Task:** Wire up Step Functions orchestration, CloudWatch alarms, and a budget enforcement layer in Terraform.

**Inputs from all previous steps:**
- Glue job name: `dns-daily-etl`
- Glue Crawler name: `dns-processed-crawler`
- Lambda ARN: `lambda_function_arn` (report generator from Step 03)
- All resources are tagged `Project = dns-log-pipeline`

**Part A — Step Functions State Machine:**

Define an `aws_sfn_state_machine` named `dns-daily-pipeline` in Amazon States Language with this exact flow:

```
StartGlueETL
  → WaitForGlueETL (poll every 30s via Choice state)
    → [SUCCEEDED] → StartGlueCrawler
      → WaitForCrawler (poll every 30s)
        → [READY] → InvokeReportLambda
          → [SUCCESS] → PipelineSucceeded
    → [FAILED at any step] → NotifyFailure (SNS Publish)
```

- Use the `Glue:startJobRun` and `Glue:getJobRun` SDK integrations for the ETL polling.
- Lambda invocation: `arn:aws:states:::lambda:invoke` with `"InvocationType": "RequestResponse"`.
- The Step Functions IAM role must have: `glue:StartJobRun`, `glue:GetJobRun`, `glue:StartCrawler`, `glue:GetCrawler`, `lambda:InvokeFunction`, `sns:Publish` — each scoped to the specific resource ARN. No wildcard actions.

**Part B — EventBridge Scheduler:**

One `aws_scheduler_schedule` named `dns-pipeline-daily-trigger`:
- Schedule: `cron(0 5 * * ? *)` (05:00 UTC)
- Target: the Step Functions state machine
- IAM role: `states:StartExecution` on that specific state machine only
- Also: set a Terraform variable `create_eventbridge_lambda_trigger = false` to disable the direct Lambda trigger provisioned in Step 03

**Part C — CloudWatch Alarms (three of them):**

1. `dns-report-generator-errors` — Lambda `Errors > 0` over 5 minutes → SNS alert
2. `dns-etl-job-failures` — Glue `glue.driver.aggregate.numFailedTasks > 100` over 5 minutes → SNS alert
3. `dns-firehose-delivery-lag` — Firehose `DeliveryToS3.DataFreshness > 900` (15 minutes) → indicates records are backing up and not reaching S3

**Part D — AWS Budget Alert:**

`aws_budgets_budget` named `dns-pipeline-monthly-budget`:
- Type: `COST`, time unit: `MONTHLY`, limit: `$800 USD`
- Filter by tag: `Project = dns-log-pipeline`
- Two notifications:
  - At **87.5% actual** ($700): warn ops team via SNS
  - At **100% forecasted** ($800): urgent alert via SNS

SNS topic: `dns-pipeline-ops-alerts`, with email subscriptions pulled from SSM parameter `/dns-pipeline/ops-emails`.

**Part E — Cost Estimate (comment block at the bottom of `main.tf`):**

```hcl
# === MONTHLY COST ESTIMATE ===
# Kinesis Firehose:    ~$113/mo  (3,900 GB @ $0.029/GB)
# S3 raw storage:      ~$90/mo   (drops sharply after 30-day Glacier IR transition)
# Glue ETL job:        ~$66/mo   (5 workers x ~30 min/day x 30 days)
# Glue Crawler:        ~$1/mo
# Athena queries:      ~$1/mo    (Parquet + partition pruning = <200 MB scanned/day)
# Lambda:              ~$0/mo    (free tier covers 1 invocation/day)
# CloudFront:          ~$5/mo    (PriceClass_100)
# SES:                 ~$0/mo    (<1,000 emails/month)
# Step Functions:      ~$0/mo    (<1,000 state transitions/month)
# CloudWatch:          ~$3/mo
# ----------------------------------
# TOTAL:               ~$279–$350/mo  (well inside the $800 cap)
# Budget headroom:     ~$450–$520/mo
```

**Outputs:** `step_function_arn`, `ops_sns_topic_arn`, `budget_name`.
