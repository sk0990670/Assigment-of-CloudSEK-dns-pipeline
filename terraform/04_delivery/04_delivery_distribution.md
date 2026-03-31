# 04 — Report Delivery & Long-Lived Distribution

### Rationale

This is the step where I've seen the most AI-generated architectures silently fail in production, so I'm going to be very explicit about what *not* to do before explaining the right approach.

The requirement says report links must remain accessible "for months or years." Almost every AI response to this will suggest S3 Pre-Signed URLs with a long expiry. This is **wrong**, and it's wrong in a way that's very hard to catch — because the code looks correct, tests pass, and then three days after you ship it, every link in every email you sent is broken.

Here's why: when AWS credentials come from an IAM Role (which is how Lambda, ECS, EC2 — everything modern — authenticates), pre-signed URLs silently inherit the role session's expiry time. That session maxes out at 12 hours by default, 36 hours absolutely. So `ExpiresIn=31536000` in your code means nothing — the URL dies with the session. AWS even documents this limitation, but most developers (and essentially all AI agents) don't know about it.

The right solution is **CloudFront in front of S3**, using an Origin Access Control (OAC). The reports sit in a private S3 bucket. CloudFront serves them publicly under a stable CDN URL that never expires. We lock the S3 bucket so only CloudFront can access it (via a bucket policy conditioned on the distribution ARN) — this means the raw S3 URLs stay inaccessible, but the CloudFront URLs work forever.

For email, we use **Amazon SES**. We don't attach the PDFs — we include CloudFront links. Attachment-based emails create deliverability problems and inflate SES costs unnecessarily. A clean HTML email with three permanent links is far better.

---

### Prompt

**Role:** You're a cloud architect who has personally debugged the pre-signed URL expiry problem in production and has strong opinions about how long-lived content distribution should be done on AWS.

**Task:** Build the CloudFront + SES delivery layer in Terraform and extend the Lambda function with email delivery logic.

**Important — read this before writing any code:**

> Do **not** use `generate_presigned_url` anywhere in this implementation. Pre-signed URLs generated from IAM Role credentials expire when the role session expires — 12 to 36 hours maximum, regardless of what `ExpiresIn` is set to. This silently breaks all links in previously sent emails. Do not work around this by making the S3 bucket public either — that's a data exposure risk.
>
> The correct approach is CloudFront with Origin Access Control. CloudFront URLs are permanent. Use them.

**Inputs from previous steps:**
- `reports_bucket_name` — S3 bucket holding generated reports
- `lambda_function_arn` — the report generator Lambda
- Report path format: `reports/YYYY-MM-DD/report_YYYY-MM-DD.{pdf,html,json}`

**Part A — CloudFront Distribution (Terraform):**

1. `aws_cloudfront_origin_access_control`:
   - Signing behavior: `always`, protocol: `sigv4`, origin type: `s3`

2. `aws_cloudfront_distribution`:
   - Origin: the reports S3 bucket, using the OAC above
   - Cache behavior: GET/HEAD only, `CachingOptimized` policy
   - Viewer protocol: `redirect-to-https`
   - Price class: **`PriceClass_100`** (US + Europe only) — not `PriceClass_All`. This is not optional; `PriceClass_All` is materially more expensive and the reports audience doesn't need global edge coverage
   - Enable: `true`

3. S3 bucket policy on the reports bucket: grant `s3:GetObject` to `cloudfront.amazonaws.com`, but **only** via a `Condition` that checks `AWS:SourceArn` matches the specific distribution ARN. No wildcard CloudFront access.

4. Output `cloudfront_domain_name`.

**Part B — SES Setup (Terraform):**

1. `aws_ses_domain_identity` for the sender domain. Add a comment noting that a human must verify the domain in the AWS console or by adding a DNS TXT record before any emails will actually send.

2. `aws_ses_configuration_set` named `dns-reports-config` with reputation metrics enabled.

3. Extend the Lambda execution role from Step 03 with `ses:SendEmail` and `ses:SendRawEmail`, scoped to the SES identity ARN only.

4. `aws_ssm_parameter` (type `StringList`) at `/dns-pipeline/report-recipients` for the list of recipient emails. Do not hardcode any email addresses in Terraform or Lambda code.

**Part C — Email delivery module (`lambda/report_generator/email_delivery.py`):**

Write a Python module exposing one function:

```python
def send_report_email(report_date, cloudfront_domain, sender_email, recipients_ssm_param):
```

It should:
- Fetch the recipient list from SSM (`get_parameter`, `WithDecryption=False`)
- Build permanent report URLs:
  ```
  https://{cloudfront_domain}/reports/{report_date}/report_{report_date}.{ext}
  ```
- Send a single HTML email via SES `send_email` with subject `DNS Daily Report — {report_date}`, containing clear links to all three formats with a note that the links don't expire
- Log success or failure per recipient without raising — one bad email address should not kill the entire delivery run

Then in `handler.py`, call `send_report_email(...)` at the end of the handler after all three files are confirmed uploaded. It reads `CLOUDFRONT_DOMAIN`, `SENDER_EMAIL`, and `RECIPIENTS_SSM_PARAM` from Lambda environment variables.

**Outputs:** `cloudfront_distribution_id`, `cloudfront_domain_name`, `ses_identity_arn`.
