# 01 — Ingestion Layer

### Rationale

First thing I ruled out: the classic ELK stack. It looks great on architecture diagrams but the moment you price it out — an EC2 cluster or a managed OpenSearch domain — you've blown the $800 budget before writing a single line of application code. Same goes for MSK (Kafka). These are enterprise tools built for teams with enterprise budgets.

What we actually need here is something that can absorb 5,000 logs per second on a quiet Tuesday *and* 100,000 logs per second during that 10-minute daily spike window, without us having to pre-provision anything for the spike. The answer is Kinesis Data Firehose. Not because it's the trendy choice — because it's the only fully-managed AWS ingestion service that literally requires zero capacity planning. It scales automatically, and you only pay for the bytes that flow through it (~$0.029/GB). At roughly 300 bytes per DNS log, our baseline burns about $113/month. That's it.

Firehose dumps directly to S3, which is the right long-term home for this data anyway. S3 is cheap, durable, and every other AWS analytics tool (Athena, Glue, QuickSight) can read from it natively. We're not indexing anything yet — that comes later. Right now the goal is: get the data safely on disk without dropping a single record, at the lowest possible cost.

One more thing worth noting: I'm configuring the S3 lifecycle to push data older than 30 days into Glacier Instant Retrieval. We rarely need to query logs from last month interactively, but we do need to keep them for compliance. Glacier IR drops the storage cost by about 80% on aging data — this matters as months of logs accumulate.

---

### Prompt

**Role:** You're an AWS solutions architect who specializes in cost-constrained, high-throughput data pipelines. You know the textbook answers (Kafka, OpenSearch, EC2 fleets) and you know when *not* to use them.

**Task:** Write production-grade Terraform for the ingestion layer of a DNS log pipeline — three files: `main.tf`, `variables.tf`, `outputs.tf`.

**What this pipeline needs to handle:**
- A steady 5,000 DNS log records per second, all day.
- A hard 10-minute burst window daily where that ramps to 100,000 records/sec. Zero loss during the spike — this is non-negotiable.
- Everything has to fit inside an $800/month total budget across all pipeline layers.

**Hard constraints — do not deviate from these:**
- No EC2 instances. No EKS. No MSK. No OpenSearch.
- Ingestion must use **Kinesis Data Firehose** with direct `PutRecordBatch` as the entry point.
- S3 is the destination.

**What to build:**

1. An S3 bucket (`dns-raw-logs-<account_id>`) for raw ingested logs.
   - Versioning off — these are write-once records, versioning just inflates cost.
   - All public access blocked.
   - Server-side encryption using SSE-S3.
   - A lifecycle rule: move objects to **S3 Glacier Instant Retrieval** after 30 days.
   - Use standalone Terraform resource blocks for encryption, public access block, and lifecycle — **not** deprecated inline arguments inside `aws_s3_bucket`.

2. A Kinesis Firehose delivery stream named `dns-log-firehose`.
   - Destination: that S3 bucket.
   - S3 prefix: `year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/`
   - Error prefix: `errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/`
   - Buffering: **128 MB or 300 seconds**, whichever triggers first. This keeps S3 PUT costs low and produces files large enough that Athena scans them efficiently later.
   - Enable GZIP compression on the S3 output.

3. An IAM role `firehose-delivery-role` with:
   - Trust policy for `firehose.amazonaws.com`.
   - Inline policy granting **only** `s3:PutObject` and `s3:PutObjectAcl` scoped to `arn:aws:s3:::dns-raw-logs-<account_id>/*`. No wildcards. No extra permissions.

4. Outputs: `firehose_stream_arn`, `s3_raw_bucket_name`, `s3_raw_bucket_arn`.
