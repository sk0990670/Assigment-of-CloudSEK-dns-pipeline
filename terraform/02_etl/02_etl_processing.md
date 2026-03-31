# 02 — ETL Processing & Data Cataloging

### Rationale

Here's a problem that's easy to miss until you get your first Athena bill: raw JSON files on S3 are expensive to query. Athena charges $5 per terabyte scanned, and it scans entire files, not just the fields you care about. With months of raw logs stacking up, a simple `COUNT(*)` query could scan hundreds of gigabytes and cost real money.

The fix is a nightly Glue ETL job that converts yesterday's raw JSON into **Parquet** — a columnar format that Athena loves. Columnar means Athena only reads the columns you actually asked for, skipping everything else. Combined with Hive-style **date partitioning**, Athena can skip entire days of data when you query a specific date range. In practice, what would've been a 500 GB scan becomes a 200 MB scan. That's the difference between $2.50 and $0.001.

Why Glue and not Lambda? Lambda has a 15-minute maximum execution time and limited memory. A day's worth of DNS logs — even compressed — is too much for Lambda to process reliably. Glue is serverless PySpark, so it distributes the processing across workers and handles arbitrary data volumes. With 5 `G.1X` workers (the smallest type), the whole previous day processes in under 30 minutes and costs roughly $2.20/day — about $66/month total. Manageable.

I'm also setting up a Glue Crawler to run after the ETL job. The Crawler is what keeps the Athena table schema current and automatically registers new date partitions, so we don't have to manually run `MSCK REPAIR TABLE` every day. Small thing, but it saves a headache.

---

### Prompt

**Role:** You're a data engineer who's built production Glue pipelines before and has opinions about when PySpark is the right tool (and when it isn't).

**Task:** Write a PySpark Glue ETL script and its supporting Terraform infrastructure to convert raw DNS logs from S3 into a partitioned Parquet dataset optimized for Athena queries.

**Inputs available from the previous step:**
- `s3_raw_bucket_name` — where Firehose is dumping raw GZIP-compressed JSON logs.
- Raw S3 prefix format: `year=YYYY/month=MM/day=DD/hour=HH/`
- Each record looks like this:
  ```json
  {
    "timestamp": "2024-01-15T03:42:11Z",
    "query_name": "api.example.com",
    "query_type": "A",
    "response_code": "NOERROR",
    "source_ip": "10.0.1.55",
    "destination_ip": "8.8.8.8",
    "resolution_ip": "93.184.216.34",
    "ttl": 300,
    "origin_region": "us-east-1"
  }
  ```

**What to build:**

**1. A second S3 bucket** (`dns-processed-logs-<account_id>`):
   - All public access blocked, SSE-S3 encryption.
   - No lifecycle policy on this one — the Parquet files are needed indefinitely for querying.

**2. A PySpark ETL script (`dns_etl.py`)** that accepts job parameters `--source_bucket`, `--target_bucket`, and `--process_date` (as `YYYY-MM-DD`):
   - Reads only the previous day's data by constructing the exact S3 prefix from `process_date`.
   - Transforms the data:
     - `timestamp` → cast to `TimestampType`
     - `ttl` → cast to `IntegerType`
     - Extract a `date` column (type `DateType`) from `timestamp` — this becomes the Hive partition column
     - `query_type` → uppercase
     - Add `is_failed` (boolean): `True` when `response_code != 'NOERROR'`
   - Writes output as **Parquet with SNAPPY compression** to `s3://dns-processed-logs-<account_id>/dns_logs/`, partitioned by `date`.
   - Use `partitionOverwriteMode = dynamic` so we overwrite only the target date partition without touching anything else.

**3. A Glue job (Terraform)** named `dns-daily-etl`:
   - Worker type: `G.1X`, number of workers: `5`.
   - Max retries: `1`, timeout: `60` minutes.
   - Upload the PySpark script to a dedicated S3 scripts prefix.
   - IAM role with **minimum permissions only**: `s3:GetObject` on the raw bucket, `s3:PutObject`/`s3:DeleteObject`/`s3:GetObject` on the processed bucket, plus Glue's own self-service permissions. That's it.

**4. A Glue Crawler** named `dns-processed-crawler`:
   - Target: the `dns_logs/` prefix in the processed bucket.
   - Glue database: create `dns_analytics`.
   - Schedule: `cron(0 6 * * ? *)` — runs at 06:00 UTC, after ETL completes.
   - This keeps the Athena table schema accurate and auto-registers new date partitions daily.

**Outputs:** `glue_database_name`, `processed_s3_bucket_name`, `glue_job_name`.
