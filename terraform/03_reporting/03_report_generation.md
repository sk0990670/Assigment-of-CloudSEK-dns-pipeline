# 03 — Daily Report Generation (PDF, HTML, JSON)

### Rationale

With clean, partitioned Parquet data sitting in S3 and Athena ready to query it, report generation is fundamentally a one-shot compute task. It happens once a day, takes a few minutes, and then it's done. There's no reason to run a persistent server or a Glue job for this — Lambda is the obvious fit.

A single Lambda function wakes up at 07:00 UTC (after the ETL job and Crawler have finished), runs three Athena queries against the `dns_analytics` database, pulls the results, and renders them into three formats. The whole thing runs in under 3 minutes and costs basically nothing — Lambda's free tier covers 1 million invocations per month, and we're using one per day.

One thing I want to be deliberate about: each Athena query must include a `WHERE date = DATE_ADD('day', -1, CURRENT_DATE)` clause. Without that partition filter, Athena will scan the entire table's history, which defeats the whole purpose of partitioning and would run up unnecessary query costs. I'm also setting a 10 GB per-query scan limit on the Athena workgroup as a safeguard.

For the PDF format, WeasyPrint is the right Python library — it converts HTML to PDF cleanly without requiring a headless browser. The catch is that WeasyPrint needs Cairo and Pango system libraries, which means the Lambda package *must* be built inside a Docker container matching the Lambda runtime. This is the kind of detail an AI will often skip unless you say it explicitly.

---

### Prompt

**Role:** You're a Python-first serverless engineer who has packaged tricky Python dependencies for Lambda before and knows the Docker-based build workflow.

**Task:** Build the daily DNS report generator: a Python Lambda function that queries Athena and produces PDF, HTML, and JSON reports, plus the Terraform to wire it all up.

**Context from previous steps:**
- Athena database: `dns_analytics`, table: `dns_logs`
- `processed_s3_bucket_name` — where the Parquet data lives
- A new `dns-reports-<account_id>` S3 bucket will be created here

**Part A — Lambda function (`lambda/report_generator/handler.py`):**

The function should do this in sequence:

1. Run these three Athena queries scoped to yesterday's partition only (`WHERE date = DATE_ADD('day', -1, CURRENT_DATE)`):

   - **Top resolvers:**
     ```sql
     SELECT query_name, COUNT(*) AS resolution_count
     FROM dns_logs
     WHERE date = DATE_ADD('day', -1, CURRENT_DATE)
     GROUP BY query_name
     ORDER BY resolution_count DESC
     LIMIT 50
     ```
   - **Total count:**
     ```sql
     SELECT COUNT(*) AS total_resolutions
     FROM dns_logs
     WHERE date = DATE_ADD('day', -1, CURRENT_DATE)
     ```
   - **Resolution origins:**
     ```sql
     SELECT origin_region, COUNT(*) AS count
     FROM dns_logs
     WHERE date = DATE_ADD('day', -1, CURRENT_DATE)
     GROUP BY origin_region
     ORDER BY count DESC
     ```

2. Write a `wait_for_query(execution_id)` helper that polls `get_query_execution` every 2 seconds, times out after 120 seconds, and raises a descriptive exception on `FAILED` or `CANCELLED` states.

3. Build a single Python dict from the results:
   ```python
   {
     "report_date": "YYYY-MM-DD",
     "generated_at": "ISO8601 UTC",
     "top_resolutions": [{"domain": str, "count": int}],
     "total_resolutions": int,
     "resolution_origins": [{"region": str, "count": int}]
   }
   ```

4. Upload these three files to `s3://dns-reports-<account_id>/reports/YYYY-MM-DD/`:
   - `report_YYYY-MM-DD.json` — serialized from the dict above
   - `report_YYYY-MM-DD.html` — rendered from an embedded Jinja2 template (inline Python string, no external files). The template must use **inline CSS only** — no CDN links — because WeasyPrint needs a self-contained document.
   - `report_YYYY-MM-DD.pdf` — `weasyprint.HTML(string=html_content).write_pdf()`

5. Return the three S3 keys on success.

**Part B — Packaging note (`README_packaging.md`):**

Include exact shell commands for building the Lambda package. WeasyPrint requires native system libraries (Cairo, Pango), so it **must** be built inside a container matching the target runtime:

```bash
docker run --rm -v $(pwd):/out public.ecr.aws/lambda/python:3.12 \
  pip install weasyprint jinja2 -t /out/package/

cd package && zip -r9 ../lambda_report.zip .
```

Explain why this step is non-negotiable — running `pip install` on a Mac or Windows dev machine will produce binaries that crash on Lambda's Linux environment.

**Part C — Terraform:**

1. S3 bucket `dns-reports-<account_id>`: private, SSE-S3, CORS enabled for GET from all origins (needed for browser access when reports are shared via links).

2. Athena workgroup `dns-analytics-wg`:
   - Result location: `s3://dns-reports-<account_id>/athena-results/`
   - Enforce workgroup settings: `true`
   - Per-query scan limit: **10 GB** (safety cutoff — normal daily queries scan under 200 MB)

3. Lambda function `dns-report-generator`:
   - Runtime `python3.12`, timeout `300` seconds, memory `1024` MB
   - Environment variables: `REPORTS_BUCKET`, `ATHENA_DATABASE`, `ATHENA_WORKGROUP`
   - IAM role with only: `athena:StartQueryExecution`, `athena:GetQueryExecution`, `athena:GetQueryResults` (scoped to the workgroup), `s3:GetObject` on the processed bucket, `s3:PutObject` on the reports bucket, `glue:GetTable`/`glue:GetDatabase` on the `dns_analytics` database

4. EventBridge Scheduler rule: `cron(0 7 * * ? *)` → triggers the Lambda. (Note: this trigger will be replaced by Step Functions in Step 05.)

**Outputs:** `reports_bucket_name`, `lambda_function_arn`.
