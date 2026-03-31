# Lambda Packaging — dns-report-generator

## Why Docker matters here

`weasyprint` uses native C libraries (Cairo & Pango) for PDF rendering. If you
run `pip install weasyprint` on macOS or Windows, pip installs platform-specific
binaries that **will crash at runtime** on Lambda's Amazon Linux 2023 environment.
The package must be built inside a container that matches the Lambda runtime.

---

## Build steps

### 1. Build dependencies inside the Lambda runtime container

```bash
# Run from the lambda/report_generator/ directory
mkdir -p package

docker run --rm \
  -v "$(pwd)/package":/var/task \
  public.ecr.aws/lambda/python:3.12 \
  pip install weasyprint jinja2 -t /var/task/
```

This installs all Python packages **and their compiled C extensions** against
Amazon Linux, so they'll work correctly inside Lambda.

### 2. Add your function source files

```bash
cp handler.py       package/
cp email_delivery.py package/
```

### 3. Create the deployment zip

```bash
cd package
zip -r9 ../lambda_report.zip .
cd ..
```

### 4. Verify the zip contents

```bash
unzip -l lambda_report.zip | head -30
# You should see weasyprint/, jinja2/, handler.py, email_delivery.py
```

### 5. Upload via Terraform or AWS CLI

```bash
# Terraform will do this automatically via the filename / source_code_hash attributes.
# Or manually:
aws lambda update-function-code \
  --function-name dns-report-generator \
  --zip-file fileb://lambda_report.zip
```

---

## Runtime requirements

| Requirement        | Value              |
|--------------------|--------------------|
| Python runtime     | `python3.12`       |
| Memory             | `1024 MB`          |
| Timeout            | `300 seconds`      |
| Zip size (approx.) | ~35 MB uncompressed |

---

## Environment variables (set in Terraform)

| Variable              | Description                                      |
|-----------------------|--------------------------------------------------|
| `REPORTS_BUCKET`      | S3 bucket name for report uploads                |
| `ATHENA_DATABASE`     | Glue database name (`dns_analytics`)             |
| `ATHENA_WORKGROUP`    | Athena workgroup name (`dns-analytics-wg`)       |
| `CLOUDFRONT_DOMAIN`   | CloudFront domain (e.g. `d1xxx.cloudfront.net`)  |
| `SENDER_EMAIL`        | SES-verified sender address                      |
| `RECIPIENTS_SSM_PARAM`| SSM parameter path for recipient list            |
