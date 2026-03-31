# DNS Log Pipeline — AI-Directed Infrastructure

> A production-grade, serverless AWS log processing pipeline built by directing an AI coding agent through a sequence of structured prompts. This repository contains both the prompt engineering strategy (`.md` files) and the full implementation code (Terraform + PySpark + Python Lambda).

---

## Table of Contents

1. [The Problem Statement](#the-problem-statement)
2. [Why This Architecture?](#why-this-architecture)
3. [How the Repository Is Organized](#how-the-repository-is-organized)
4. [Prerequisites](#prerequisites)
5. [Step-by-Step Setup Guide](#step-by-step-setup-guide)
   - [Step 1 — Install AWS CLI](#step-1--install-aws-cli)
   - [Step 2 — Configure AWS Credentials](#step-2--configure-aws-credentials)
   - [Step 3 — Install Terraform](#step-3--install-terraform)
   - [Step 4 — Install Docker](#step-4--install-docker)
   - [Step 5 — Verify SES Domain](#step-5--verify-ses-domain)
   - [Step 6 — Deploy Layer 01: Ingestion](#step-6--deploy-layer-01-ingestion)
   - [Step 7 — Deploy Layer 02: ETL](#step-7--deploy-layer-02-etl)
   - [Step 8 — Build and Deploy Lambda Package](#step-8--build-and-deploy-lambda-package)
   - [Step 9 — Deploy Layer 03: Reporting](#step-9--deploy-layer-03-reporting)
   - [Step 10 — Deploy Layer 04: Delivery](#step-10--deploy-layer-04-delivery)
   - [Step 11 — Deploy Layer 05: Orchestration](#step-11--deploy-layer-05-orchestration)
   - [Step 12 — Update Recipient List](#step-12--update-recipient-list)
6. [Testing the Pipeline](#testing-the-pipeline)
7. [Cost Breakdown](#cost-breakdown)
8. [Teardown](#teardown)

---

## The Problem Statement

### What Are We Building?

A **fully serverless DNS log processing pipeline** on AWS that must meet all of the following requirements simultaneously:

| Requirement | Detail |
|---|---|
| **Ingestion throughput** | 5,000 DNS logs/sec baseline, with 10-minute daily spikes up to 100,000 logs/sec |
| **Zero data loss** | The spike window cannot drop a single record |
| **Data payload** | DNS queries, response codes, source/destination IPs, TTL, origin region |
| **Processing** | Buffer, transform, and index logs for structured querying |
| **Daily reports** | PDF, HTML, and JSON formats showing top resolutions, total counts, and origins |
| **Email delivery** | Reports delivered daily with **permanently accessible** links (months or years) |
| **Budget** | Entire pipeline must cost under **$800/month** |

### Why Is This Hard?

The naive answers all fail:

- **ELK Stack (Elasticsearch + Logstash + Kibana)** — A managed OpenSearch domain alone costs $500–$2,000/month before you've processed a single log. Instantly over budget.
- **Apache Kafka (MSK)** — MSK clusters have a minimum cost of ~$400/month even at idle. Also over budget.
- **EC2 Auto Scaling fleet** — Pre-provisioning for 100,000 logs/sec means paying for idle capacity 23 hours and 50 minutes a day.
- **S3 Pre-Signed URLs** for "long-lived links" — The most common AI mistake: pre-signed URLs generated from IAM Role credentials expire with the role session (maximum 12–36 hours), regardless of the `ExpiresIn` value you set. Every historical link breaks silently.

The solution this pipeline implements avoids all of these traps using a fully pay-per-use, serverless architecture.

---

## Why This Architecture?

Each service choice is deliberate and cost-justified:

| Service | Role | Why Not the Alternative |
|---|---|---|
| **Kinesis Data Firehose** | Ingest logs → S3 | Auto-scales to 100k/sec with zero provisioning. Charged per GB ($0.029/GB). Kafka would cost 10× more at idle. |
| **S3 + Glacier IR** | Raw log storage | Durable, cheap, natively integrated with every AWS analytics tool. Glacier IR cuts storage cost 80% after 30 days. |
| **AWS Glue (PySpark)** | Nightly ETL to Parquet | Converts raw JSON → columnar Parquet, cutting Athena query costs by 95–99% through column pruning + partition skipping. |
| **Amazon Athena** | Query engine | Serverless SQL over S3. $5/TB scanned — with Parquet + partitioning, daily report queries cost under $0.01. |
| **AWS Lambda** | Report generation | One invocation per day → fractions of a cent. No idle cost, no servers, handles PDF/HTML/JSON generation in <3 minutes. |
| **CloudFront + OAC** | Report distribution | Permanent, non-expiring HTTPS URLs backed by a private S3 bucket. The only correct answer for "links that last years." |
| **Amazon SES** | Email delivery | $0.10 per 1,000 emails. For a daily report to a small team, monthly cost is essentially $0. |
| **Step Functions** | Orchestration | Chains ETL → Crawler → Lambda with explicit failure handling. If the ETL job fails, everything downstream stops — not just cron'd independently. |

---

## How the Repository Is Organized

```
.
├── 01_infrastructure_ingestion.md   ← Prompt 1: Why Firehose? + AI prompt to build it
├── 02_etl_processing.md             ← Prompt 2: Why Glue + Parquet? + AI prompt
├── 03_report_generation.md          ← Prompt 3: Why Lambda + Athena? + AI prompt
├── 04_delivery_distribution.md      ← Prompt 4: Why CloudFront (not pre-signed URLs)? + AI prompt
├── 05_orchestration_monitoring.md   ← Prompt 5: Why Step Functions? + AI prompt
├── review_and_correct.md            ← The pre-signed URL hallucination catch
│
└── dns-pipeline/                    ← All generated implementation code
    ├── terraform/
    │   ├── 01_ingestion/            → Firehose + S3 raw bucket + IAM
    │   ├── 02_etl/                  → Glue job + Crawler + processed S3 bucket
    │   ├── 03_reporting/            → Lambda + Athena workgroup + reports S3
    │   ├── 04_delivery/             → CloudFront + SES + SSM
    │   └── 05_orchestration/        → Step Functions + EventBridge + Budgets
    ├── glue/
    │   └── dns_etl.py               → PySpark ETL: raw JSON → Parquet
    └── lambda/
        └── report_generator/
            ├── handler.py           → Athena queries + PDF/HTML/JSON generation
            ├── email_delivery.py    → SES delivery with CloudFront links
            └── README_packaging.md  → Docker build instructions for Lambda
```

The `.md` files are the **prompt engineering strategy** — they contain the human reasoning (under `### Rationale`) and the exact AI instructions (under `### Prompt`) used to generate the code in `dns-pipeline/`.

---

## Prerequisites

Before you begin, make sure you have:

- An **AWS account** with permissions to create IAM roles, S3 buckets, Kinesis streams, Glue jobs, Lambda functions, CloudFront distributions, SES identities, and Step Functions.
- A **domain name** you control — needed to verify a sender identity in SES.
- A machine running **Linux, macOS, or Windows with WSL2** (all commands below are bash-compatible).

---

## Step-by-Step Setup Guide

### Step 1 — Install AWS CLI

**Why:** Every Terraform AWS provider call and manual verification step goes through the AWS CLI. Without it, you cannot authenticate to your account or run verification commands.

```bash
# Linux / WSL2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# macOS (Homebrew)
brew install awscli

# Windows
# Download the MSI installer from:
# https://awscli.amazonaws.com/AWSCLIV2.msi
```

Verify it's installed:

```bash
aws --version
# Expected output: aws-cli/2.x.x Python/3.x.x ...
```

---

### Step 2 — Configure AWS Credentials

**Why:** Terraform uses the AWS SDK under the hood. It needs valid credentials with sufficient permissions to create all the resources in this pipeline. Without this step, every `terraform apply` will fail with an authentication error.

```bash
aws configure
```

You'll be prompted for:

```
AWS Access Key ID [None]: <your-access-key-id>
AWS Secret Access Key [None]: <your-secret-access-key>
Default region name [None]: us-east-1
Default output format [None]: json
```

> **Where to get credentials:** AWS Console → IAM → Users → your user → Security credentials → Create access key.
>
> The IAM user needs at minimum: `AdministratorAccess` (for initial setup) or a custom policy covering S3, Kinesis Firehose, Glue, Lambda, CloudFront, SES, Step Functions, IAM, CloudWatch, and EventBridge.

Verify the credentials work:

```bash
aws sts get-caller-identity
# Expected: JSON showing your Account, UserId, and ARN
```

Note your **Account ID** from this output — you'll need it as a Terraform variable.

---

### Step 3 — Install Terraform

**Why:** All five infrastructure layers in this project are defined as Terraform configurations. Terraform is the tool that reads those `.tf` files and creates the actual AWS resources.

```bash
# Linux / WSL2 — using tfenv (recommended for version management)
git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
tfenv install 1.9.0
tfenv use 1.9.0

# macOS (Homebrew)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Windows
# Download the zip from https://developer.hashicorp.com/terraform/downloads
# Extract terraform.exe and add to your PATH
```

Verify the installation:

```bash
terraform -version
# Expected: Terraform v1.9.x
```

---

### Step 4 — Install Docker

**Why:** The Lambda function uses `weasyprint` for PDF generation. WeasyPrint depends on native C libraries (Cairo, Pango). If you build the Python package on your local machine, it compiles against your OS. Lambda runs on Amazon Linux 2023 — the binaries won't match and the function will crash at runtime. Docker lets you build the package inside an exact replica of the Lambda runtime environment.

```bash
# Linux
sudo apt-get update && sudo apt-get install -y docker.io
sudo systemctl start docker
sudo usermod -aG docker $USER   # log out and back in after this

# macOS
# Install Docker Desktop from https://www.docker.com/products/docker-desktop

# Windows
# Install Docker Desktop (requires WSL2 backend)
# https://docs.docker.com/desktop/install/windows-install/
```

Verify Docker is running:

```bash
docker run hello-world
```

---

### Step 5 — Verify SES Domain

**Why:** AWS SES requires domain ownership verification before it allows you to send emails. This is a one-time manual DNS step — Terraform cannot do it for you because it requires you to add a record to your external DNS provider (GoDaddy, Cloudflare, Route 53, etc.).

```bash
# After deploying layer 04 (later), get your verification token:
aws ses get-domain-dkim --domain yourdomain.com

# Add the three CNAME records shown to your DNS provider.
# Then check verification status:
aws ses get-identity-verification-attributes --identities yourdomain.com
```

Wait for status to show `"VerificationStatus": "Success"` before the first report email is due.

> **You can still deploy and test the full pipeline before this step — reports will upload to S3 and CloudFront correctly. Only the email delivery step will fail until SES is verified.**

---

### Step 6 — Deploy Layer 01: Ingestion

**Why this layer exists:** This creates the Firehose delivery stream and raw S3 bucket. Until these exist, there is nowhere to send DNS logs, and no data for the ETL job to process.

```bash
cd dns-pipeline/terraform/01_ingestion

terraform init
```

Create a `terraform.tfvars` file:

```hcl
# terraform.tfvars
aws_account_id = "123456789012"   # replace with your actual account ID
aws_region     = "us-east-1"
```

Apply:

```bash
terraform plan
terraform apply
```

Type `yes` when prompted. This creates:
- `dns-raw-logs-<account_id>` S3 bucket with GZIP storage and Glacier IR lifecycle
- `dns-log-firehose` Kinesis Firehose stream (buffers 128 MB / 300 seconds before flushing to S3)

Note the outputs — you'll use them in the next layer:

```bash
terraform output
# firehose_stream_arn = "arn:aws:firehose:..."
# s3_raw_bucket_name  = "dns-raw-logs-123456789012"
# s3_raw_bucket_arn   = "arn:aws:s3:::dns-raw-logs-123456789012"
```

---

### Step 7 — Deploy Layer 02: ETL

**Why this layer exists:** Raw Firehose output is GZIP-compressed JSON — expensive to query directly with Athena. This layer sets up the Glue ETL job that converts it nightly to Parquet (columnar, SNAPPY-compressed, date-partitioned), which cuts Athena query costs by 95–99%.

```bash
cd ../02_etl
```

Create `terraform.tfvars`:

```hcl
aws_account_id      = "123456789012"
aws_region          = "us-east-1"
s3_raw_bucket_name  = "dns-raw-logs-123456789012"   # from layer 01 output
```

Apply:

```bash
terraform init
terraform apply
```

This creates:
- `dns-processed-logs-<account_id>` S3 bucket for Parquet output
- `dns-daily-etl` Glue job (5 × G.1X workers, uploads the PySpark script automatically)
- `dns-analytics` Glue catalog database
- `dns-processed-crawler` Glue Crawler (scheduled 06:00 UTC)

```bash
terraform output
# glue_database_name        = "dns_analytics"
# processed_s3_bucket_name  = "dns-processed-logs-123456789012"
# glue_job_name             = "dns-daily-etl"
# glue_crawler_name         = "dns-processed-crawler"
```

---

### Step 8 — Build and Deploy Lambda Package

**Why this step is separate:** The Lambda uses `weasyprint` for PDF generation, which requires native compiled libraries. These must be built inside a Docker container matching the Lambda runtime (Amazon Linux 2023 / Python 3.12). Skipping this step will cause the Lambda to crash with a `ImportError` on the first invocation.

```bash
cd ../../lambda/report_generator

# Build dependencies inside the Lambda runtime container
mkdir -p package
docker run --rm \
  -v "$(pwd)/package":/var/task \
  public.ecr.aws/lambda/python:3.12 \
  pip install weasyprint jinja2 -t /var/task/

# Add your source files to the package
cp handler.py       package/
cp email_delivery.py package/

# Zip everything up
cd package
zip -r9 ../lambda_report.zip .
cd ..

# Verify the zip contains what you expect
unzip -l lambda_report.zip | grep -E "handler|email_delivery|weasyprint|jinja2" | head -20
```

You should see `handler.py`, `email_delivery.py`, `weasyprint/`, and `jinja2/` in the listing.

---

### Step 9 — Deploy Layer 03: Reporting

**Why this layer exists:** This creates the Lambda function and Athena workgroup. The Lambda is the engine that queries Athena for yesterday's data and renders the three report formats. The Athena workgroup enforces a 10 GB per-query scan limit as a cost safety net.

```bash
cd ../../terraform/03_reporting
```

Copy the built Lambda zip here first:

```bash
cp ../../lambda/report_generator/lambda_report.zip .
```

Create `terraform.tfvars`:

```hcl
aws_account_id            = "123456789012"
aws_region                = "us-east-1"
processed_s3_bucket_name  = "dns-processed-logs-123456789012"
processed_s3_bucket_arn   = "arn:aws:s3:::dns-processed-logs-123456789012"
glue_database_name        = "dns_analytics"
```

> **Before applying:** Open `main.tf` and update the `filename` in `aws_lambda_function.report_generator` to point to `lambda_report.zip` instead of the placeholder. Also update `source_code_hash` to use `filebase64sha256("lambda_report.zip")`.

```bash
terraform init
terraform apply
```

```bash
terraform output
# reports_bucket_name   = "dns-reports-123456789012"
# lambda_function_arn   = "arn:aws:lambda:..."
# lambda_function_name  = "dns-report-generator"
# lambda_role_name      = "dns-report-lambda-role"
```

---

### Step 10 — Deploy Layer 04: Delivery

**Why this layer exists:** This creates the CloudFront distribution that serves reports via permanent URLs, and wires up SES for email delivery. This is also where the critical anti-mistake lives — using CloudFront instead of pre-signed URLs, which would silently expire within hours.

```bash
cd ../04_delivery
```

Create `terraform.tfvars`:

```hcl
aws_account_id        = "123456789012"
aws_region            = "us-east-1"
reports_bucket_name   = "dns-reports-123456789012"
reports_bucket_arn    = "arn:aws:s3:::dns-reports-123456789012"
lambda_function_arn   = "arn:aws:lambda:us-east-1:123456789012:function:dns-report-generator"
lambda_role_name      = "dns-report-lambda-role"
sender_domain         = "yourdomain.com"
```

```bash
terraform init
terraform apply
```

This creates:
- CloudFront distribution with Origin Access Control — the S3 bucket stays private
- SES domain identity (you still need to verify it manually — see Step 5)
- SSM parameter `/dns-pipeline/report-recipients` with a placeholder recipient

```bash
terraform output
# cloudfront_domain_name = "d1xxxxxxxxxxxxx.cloudfront.net"
# ses_identity_arn       = "arn:aws:ses:..."
```

Now update the Lambda environment variables with the CloudFront domain:

```bash
aws lambda update-function-configuration \
  --function-name dns-report-generator \
  --environment "Variables={
    REPORTS_BUCKET=dns-reports-123456789012,
    ATHENA_DATABASE=dns_analytics,
    ATHENA_WORKGROUP=dns-analytics-wg,
    CLOUDFRONT_DOMAIN=d1xxxxxxxxxxxxx.cloudfront.net,
    SENDER_EMAIL=noreply@yourdomain.com,
    RECIPIENTS_SSM_PARAM=/dns-pipeline/report-recipients
  }"
```

---

### Step 11 — Deploy Layer 05: Orchestration

**Why this layer exists:** Previously, each component (Glue job, Crawler, Lambda) ran on its own independent cron schedule. If the ETL job fails, the Crawler still runs on stale data, and the Lambda still generates a garbage report. Step Functions chains them into a sequential, dependency-aware workflow with proper failure handling and SNS alerting.

```bash
cd ../05_orchestration
```

Create `terraform.tfvars`:

```hcl
aws_account_id        = "123456789012"
aws_region            = "us-east-1"
glue_job_name         = "dns-daily-etl"
glue_crawler_name     = "dns-processed-crawler"
lambda_function_arn   = "arn:aws:lambda:us-east-1:123456789012:function:dns-report-generator"
lambda_function_name  = "dns-report-generator"
reports_bucket_arn    = "arn:aws:s3:::dns-reports-123456789012"
```

```bash
terraform init
terraform apply
```

This creates:
- `dns-daily-pipeline` Step Functions state machine (ETL → Crawler → Lambda, with SNS on any failure)
- EventBridge Scheduler firing at **05:00 UTC daily**
- CloudWatch alarms on Lambda errors and Firehose delivery lag
- An AWS Budget alerting at $700 actual and $800 forecasted spend

```bash
terraform output
# step_function_arn = "arn:aws:states:..."
# ops_sns_topic_arn = "arn:aws:sns:..."
# budget_name       = "dns-pipeline-monthly-budget"
```

---

### Step 12 — Update Recipient List

**Why:** Terraform intentionally ignores changes to the SSM parameter value after the first apply (via `lifecycle { ignore_changes = [value] }`). This prevents Terraform from reverting your production recipient list every time you re-apply infra changes.

Update recipients via the AWS CLI:

```bash
aws ssm put-parameter \
  --name "/dns-pipeline/report-recipients" \
  --value "alice@example.com,bob@example.com,team@example.com" \
  --type StringList \
  --overwrite
```

---

## Testing the Pipeline

### Test Firehose ingestion manually

Send a sample log record directly to Firehose to verify the ingestion layer:

```bash
aws firehose put-record \
  --delivery-stream-name dns-log-firehose \
  --record '{"Data":"eyJ0aW1lc3RhbXAiOiAiMjAyNS0wMS0xNVQwMzowMDowMFoiLCAicXVlcnlfbmFtZSI6ICJleGFtcGxlLmNvbSIsICJxdWVyeV90eXBlIjogIkEiLCAicmVzcG9uc2VfY29kZSI6ICJOT0VSUk9SIiwgInNvdXJjZV9pcCI6ICIxMC4wLjAuMSIsICJkZXN0aW5hdGlvbl9pcCI6ICI4LjguOC44IiwgInJlc29sdXRpb25faXAiOiAiOTMuMTg0LjIxNi4zNCIsICJ0dGwiOiAzMDAsICJvcmlnaW5fcmVnaW9uIjogInVzLWVhc3QtMSJ9Cg=="}'
```

Within 5 minutes (Firehose buffer), you should see a file appear in `s3://dns-raw-logs-<account_id>/year=.../`.

### Test the ETL job manually

```bash
aws glue start-job-run \
  --job-name dns-daily-etl \
  --arguments '{"--process_date":"2025-01-15"}'

# Watch the run status
aws glue get-job-runs --job-name dns-daily-etl --max-results 1
```

### Test the Lambda report generator manually

```bash
aws lambda invoke \
  --function-name dns-report-generator \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json
```

Check the reports bucket for the generated files:

```bash
aws s3 ls s3://dns-reports-<account_id>/reports/ --recursive
```

### Test the full Step Functions pipeline

```bash
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:us-east-1:123456789012:stateMachine:dns-daily-pipeline" \
  --input '{}'

# Watch execution
aws stepfunctions list-executions \
  --state-machine-arn "arn:aws:states:us-east-1:123456789012:stateMachine:dns-daily-pipeline" \
  --max-results 1
```

---

## Cost Breakdown

| Service | Monthly Estimate | Notes |
|---|---|---|
| Kinesis Data Firehose | ~$113 | 3,900 GB/month @ $0.029/GB |
| S3 Raw Storage | ~$90 | First 30 days; drops ~80% as data ages into Glacier IR |
| Glue ETL Job | ~$66 | 5 × G.1X workers, ~30 min/day |
| Glue Crawler | ~$1 | Daily 5-minute run |
| Athena Queries | ~$1 | Parquet + partition pruning → <200 MB scanned/day |
| Lambda | ~$0 | 1 invocation/day — within permanent free tier |
| CloudFront | ~$5 | PriceClass_100 (US + Europe) |
| SES | ~$0 | <1,000 emails/month |
| Step Functions | ~$0 | ~10 state transitions/day |
| CloudWatch + SNS | ~$3 | Dashboards, alarms, notifications |
| **Total** | **~$279–$350** | **$450–$520 under the $800 budget cap** |

---

## Teardown

To destroy all resources and stop incurring charges, tear down in reverse order:

```bash
# Disable the bucket's prevent_destroy before destroying layer 01
# Edit 01_ingestion/main.tf and set prevent_destroy = false, then re-apply first.

cd dns-pipeline/terraform/05_orchestration && terraform destroy
cd ../04_delivery                          && terraform destroy
cd ../03_reporting                         && terraform destroy
cd ../02_etl                               && terraform destroy
cd ../01_ingestion                         && terraform destroy
```

> **Warning:** Destroying the raw logs bucket (`01_ingestion`) will permanently delete all ingested DNS logs. Export anything you need to preserve before running `terraform destroy` on that layer.

---

## License

MIT — see [LICENSE](LICENSE) for details.
