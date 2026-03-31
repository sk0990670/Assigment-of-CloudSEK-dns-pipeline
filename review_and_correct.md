# review_and_correct

### Rationale

The single most dangerous hallucination in this entire project isn't an obvious mistake — it's a subtle one that looks completely correct, passes code review, and only fails silently in production weeks later.

When you ask an AI to solve "report links must remain accessible for months or years," it will almost always suggest **S3 Pre-Signed URLs** with a long `ExpiresIn` value. The code looks like this:

```python
url = s3_client.generate_presigned_url(
    'get_object',
    Params={'Bucket': bucket, 'Key': key},
    ExpiresIn=31536000  # the AI thinks this means "1 year"
)
```

This looks reasonable. But here's what the AI doesn't know — or doesn't tell you:

When AWS credentials come from an **IAM Role** (which is how every serverless AWS service authenticates — Lambda, ECS, EC2 with instance profiles, Glue, etc.), pre-signed URLs are signed with temporary session credentials. Those session credentials have a maximum lifetime of **12 hours by default, and 36 hours at the absolute maximum, regardless of what `ExpiresIn` says**. AWS's own documentation states:

> *"If you created a presigned URL using a temporary token, the URL expires when the token expires, even if the URL was created with a later expiration time."*

So the URL expires in hours. The email goes out. Everyone clicks the links while they're fresh and nothing seems wrong. Then someone digs up last month's report email and clicks the PDF link — `AccessDenied`. Every historical report link is broken. This is a production bug that's invisible during testing and extremely confusing to debug.

---

### The Flaw

**Type:** Silent reliability failure / security flaw  
**Root cause:** Using IAM-role-generated pre-signed URLs for content that must remain accessible long-term  
**Why AI agents miss it:** The `ExpiresIn` parameter *looks* like it controls URL lifetime. The role session override is buried in AWS documentation that doesn't appear in most search results or training data.

There's a secondary mistake that some AI agents make when told pre-signed URLs won't work: they suggest making the **S3 bucket itself public** (`aws_s3_bucket_acl { acl = "public-read" }`). This is worse — it exposes the entire bucket to the internet, including raw DNS logs containing source IPs, internal domain resolution patterns, and infrastructure metadata. That's a real data breach waiting to happen.

---

### The Instruction Added to Prevent It

I embedded this explicit block at the **top** of Prompt 04 (`04_delivery_distribution.md`), before any requirements, so it shapes the entire response:

> **"Do not use `generate_presigned_url` anywhere in this implementation.** When credentials come from an IAM Role (which Lambda always uses), pre-signed URLs expire when the role session expires — maximum 12 to 36 hours, regardless of the `ExpiresIn` value set in code. Every link in every report email will stop working within hours. This silently breaks the 'accessible for months or years' requirement.
>
> Do not work around this by making the S3 bucket public. That exposes raw DNS logs and report data to the open internet.
>
> The correct solution is a **CloudFront distribution** backed by the S3 reports bucket using an **Origin Access Control (OAC)**. The bucket stays fully private. CloudFront receives a bucket policy granting it access, conditioned on the specific distribution's ARN. CloudFront URLs are permanent — they never expire. Use these URLs in the emails."

Putting this at the top matters. AI agents write code top-to-bottom, and if the constraint comes at the end of a long requirements section, the agent has already committed to a mental model of the solution. Leading with the anti-pattern explicitly prevents the hallucination before it forms.
