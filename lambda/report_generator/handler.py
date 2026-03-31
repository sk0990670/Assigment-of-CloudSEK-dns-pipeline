"""
handler.py — Lambda entry point for the DNS daily report generator.

Triggered by Step Functions at 07:00 UTC after Glue ETL + Crawler complete.
Queries Athena for yesterday's DNS data, then produces PDF, HTML, and JSON
reports, uploading all three to the reports S3 bucket.
"""

import json
import os
import time
from datetime import date, timedelta, timezone, datetime

import boto3

import email_delivery

# ── Clients ──────────────────────────────────────────────────────────────────

athena   = boto3.client("athena")
s3       = boto3.client("s3")

# ── Config from environment ───────────────────────────────────────────────────

REPORTS_BUCKET      = os.environ["REPORTS_BUCKET"]
ATHENA_DATABASE     = os.environ["ATHENA_DATABASE"]
ATHENA_WORKGROUP    = os.environ["ATHENA_WORKGROUP"]
CLOUDFRONT_DOMAIN   = os.environ.get("CLOUDFRONT_DOMAIN", "")
SENDER_EMAIL        = os.environ.get("SENDER_EMAIL", "")
RECIPIENTS_SSM_PARAM = os.environ.get("RECIPIENTS_SSM_PARAM", "")

# ── Athena helpers ────────────────────────────────────────────────────────────

def run_query(sql: str) -> str:
    """Submit a query to Athena and return its execution ID."""
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": ATHENA_DATABASE},
        WorkGroup=ATHENA_WORKGROUP,
    )
    return resp["QueryExecutionId"]


def wait_for_query(execution_id: str, timeout_seconds: int = 120) -> None:
    """
    Poll Athena until the query succeeds or fails.
    Raises RuntimeError on failure or timeout — a failed query should
    abort report generation rather than silently produce empty results.
    """
    deadline = time.time() + timeout_seconds

    while time.time() < deadline:
        resp   = athena.get_query_execution(QueryExecutionId=execution_id)
        state  = resp["QueryExecution"]["QueryExecutionStatus"]["State"]

        if state == "SUCCEEDED":
            return

        if state in ("FAILED", "CANCELLED"):
            reason = resp["QueryExecution"]["QueryExecutionStatus"].get(
                "StateChangeReason", "No reason provided"
            )
            raise RuntimeError(
                f"Athena query {execution_id} ended with state {state}: {reason}"
            )

        # Still running — sleep and retry
        time.sleep(2)

    raise TimeoutError(
        f"Athena query {execution_id} did not complete within {timeout_seconds}s"
    )


def fetch_results(execution_id: str) -> list[dict]:
    """
    Pull paginated Athena results and return them as a list of dicts,
    using the first row as column headers.
    """
    rows = []
    paginator = athena.get_paginator("get_query_results")

    headers = None
    for page in paginator.paginate(QueryExecutionId=execution_id):
        for i, row in enumerate(page["ResultSet"]["Rows"]):
            cells = [c.get("VarCharValue", "") for c in row["Data"]]
            if headers is None:
                headers = cells          # first row is always the header
                continue
            rows.append(dict(zip(headers, cells)))

    return rows


# ── Queries ───────────────────────────────────────────────────────────────────

TOP_RESOLVERS_SQL = """
SELECT query_name,
       COUNT(*) AS resolution_count
FROM   dns_logs
WHERE  date = DATE_ADD('day', -1, CURRENT_DATE)
GROUP  BY query_name
ORDER  BY resolution_count DESC
LIMIT  50
"""

TOTAL_COUNT_SQL = """
SELECT COUNT(*) AS total_resolutions
FROM   dns_logs
WHERE  date = DATE_ADD('day', -1, CURRENT_DATE)
"""

ORIGINS_SQL = """
SELECT origin_region,
       COUNT(*) AS count
FROM   dns_logs
WHERE  date = DATE_ADD('day', -1, CURRENT_DATE)
GROUP  BY origin_region
ORDER  BY count DESC
"""


# ── HTML Template (inline — no external CDN links; WeasyPrint needs it) ───────

REPORT_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>DNS Daily Report — {{ report_date }}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;
      font-size: 13px;
      color: #1a1a2e;
      background: #f7f8fc;
      padding: 32px;
    }
    h1 { font-size: 22px; font-weight: 700; color: #0f3460; margin-bottom: 4px; }
    .meta { color: #555; font-size: 11px; margin-bottom: 28px; }
    h2 { font-size: 15px; font-weight: 600; color: #16213e; margin: 24px 0 10px; border-bottom: 2px solid #e2e8f0; padding-bottom: 6px; }
    .summary-grid { display: flex; gap: 20px; margin-bottom: 8px; }
    .card { background: #fff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 22px; min-width: 180px; }
    .card .label { font-size: 11px; color: #888; text-transform: uppercase; letter-spacing: 0.05em; }
    .card .value { font-size: 28px; font-weight: 700; color: #0f3460; margin-top: 4px; }
    table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; border: 1px solid #e2e8f0; }
    th { background: #0f3460; color: #fff; text-align: left; padding: 9px 14px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; }
    td { padding: 8px 14px; border-bottom: 1px solid #f0f4f8; }
    tr:last-child td { border-bottom: none; }
    tr:nth-child(even) td { background: #f8fafc; }
    .rank { color: #aaa; font-size: 11px; }
    .bar-wrap { background: #e9ecef; border-radius: 4px; height: 8px; }
    .bar { background: #0f3460; border-radius: 4px; height: 8px; }
  </style>
</head>
<body>
  <h1>DNS Daily Report</h1>
  <p class="meta">Date: {{ report_date }} &nbsp;|&nbsp; Generated: {{ generated_at }} UTC</p>

  <h2>Summary</h2>
  <div class="summary-grid">
    <div class="card">
      <div class="label">Total Resolutions</div>
      <div class="value">{{ "{:,}".format(total_resolutions) }}</div>
    </div>
    <div class="card">
      <div class="label">Unique Domains (Top 50)</div>
      <div class="value">{{ top_resolutions | length }}</div>
    </div>
    <div class="card">
      <div class="label">Origin Regions</div>
      <div class="value">{{ resolution_origins | length }}</div>
    </div>
  </div>

  <h2>Top 50 DNS Resolutions</h2>
  <table>
    <thead>
      <tr>
        <th>#</th>
        <th>Domain</th>
        <th>Resolutions</th>
        <th>Share</th>
      </tr>
    </thead>
    <tbody>
      {% for row in top_resolutions %}
      {% set pct = (row.count / total_resolutions * 100) if total_resolutions > 0 else 0 %}
      <tr>
        <td class="rank">{{ loop.index }}</td>
        <td>{{ row.domain }}</td>
        <td>{{ "{:,}".format(row.count) }}</td>
        <td>
          <div class="bar-wrap">
            <div class="bar" style="width: {{ [pct, 100]|min }}%"></div>
          </div>
          {{ "%.2f"|format(pct) }}%
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>

  <h2>Resolution Origins by Region</h2>
  <table>
    <thead>
      <tr><th>Region</th><th>Count</th></tr>
    </thead>
    <tbody>
      {% for row in resolution_origins %}
      <tr>
        <td>{{ row.region }}</td>
        <td>{{ "{:,}".format(row.count) }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</body>
</html>"""


# ── Report builder ────────────────────────────────────────────────────────────

def build_report_data(report_date: str) -> dict:
    """Run all three Athena queries concurrently (submit all, then wait)."""
    print("[Report] Submitting Athena queries...")

    qid_top    = run_query(TOP_RESOLVERS_SQL)
    qid_total  = run_query(TOTAL_COUNT_SQL)
    qid_origin = run_query(ORIGINS_SQL)

    print(f"[Report] Query IDs: top={qid_top}, total={qid_total}, origin={qid_origin}")

    for qid in (qid_top, qid_total, qid_origin):
        wait_for_query(qid)

    top_rows    = fetch_results(qid_top)
    total_rows  = fetch_results(qid_total)
    origin_rows = fetch_results(qid_origin)

    total_count = int(total_rows[0]["total_resolutions"]) if total_rows else 0

    return {
        "report_date":        report_date,
        "generated_at":       datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total_resolutions":  total_count,
        "top_resolutions": [
            {"domain": r["query_name"], "count": int(r["resolution_count"])}
            for r in top_rows
        ],
        "resolution_origins": [
            {"region": r["origin_region"], "count": int(r["count"])}
            for r in origin_rows
        ],
    }


def render_html(data: dict) -> str:
    from jinja2 import BaseLoader, Environment
    env = Environment(loader=BaseLoader())
    tmpl = env.from_string(REPORT_TEMPLATE)
    return tmpl.render(**data)


def render_pdf(html: str) -> bytes:
    import weasyprint
    return weasyprint.HTML(string=html).write_pdf()


def upload(body: bytes | str, key: str, content_type: str) -> None:
    if isinstance(body, str):
        body = body.encode("utf-8")
    s3.put_object(
        Bucket=REPORTS_BUCKET,
        Key=key,
        Body=body,
        ContentType=content_type,
    )
    print(f"[Upload] s3://{REPORTS_BUCKET}/{key}")


# ── Lambda handler ────────────────────────────────────────────────────────────

def handler(event, context):
    report_date = (date.today() - timedelta(days=1)).isoformat()
    prefix      = f"reports/{report_date}"

    print(f"[Handler] Generating report for {report_date}")

    # Build data
    data = build_report_data(report_date)

    # JSON
    json_key = f"{prefix}/report_{report_date}.json"
    upload(json.dumps(data, indent=2), json_key, "application/json")

    # HTML
    html_content = render_html(data)
    html_key     = f"{prefix}/report_{report_date}.html"
    upload(html_content, html_key, "text/html")

    # PDF
    pdf_bytes = render_pdf(html_content)
    pdf_key   = f"{prefix}/report_{report_date}.pdf"
    upload(pdf_bytes, pdf_key, "application/pdf")

    keys = {"json": json_key, "html": html_key, "pdf": pdf_key}
    print(f"[Handler] All reports uploaded: {keys}")

    # Email delivery — failures are logged but do not abort the handler
    if CLOUDFRONT_DOMAIN and SENDER_EMAIL and RECIPIENTS_SSM_PARAM:
        try:
            email_delivery.send_report_email(
                report_date=report_date,
                cloudfront_domain=CLOUDFRONT_DOMAIN,
                sender_email=SENDER_EMAIL,
                recipients_ssm_param=RECIPIENTS_SSM_PARAM,
            )
        except Exception as exc:
            # Email failure is non-fatal — reports are already uploaded
            print(f"[Handler] WARNING: Email delivery raised an exception: {exc}")
    else:
        print("[Handler] Email env vars not set — skipping delivery.")

    return {"statusCode": 200, "report_date": report_date, "keys": keys}
