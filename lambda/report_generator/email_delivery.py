"""
email_delivery.py — SES email delivery for DNS daily reports.

Sends a single HTML email per recipient containing permanent CloudFront links
to the PDF, HTML, and JSON report files.

NOTE: CloudFront URLs are used intentionally.
S3 pre-signed URLs generated from IAM Role credentials expire with the role
session (12–36 hours max), making them unusable for long-term report access.
CloudFront URLs backed by a private S3 bucket are permanent.
"""

import logging

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm")
ses = boto3.client("ses")


def _get_recipients(ssm_param_name: str) -> list[str]:
    """Fetch the recipient email list from SSM Parameter Store."""
    resp  = ssm.get_parameter(Name=ssm_param_name, WithDecryption=False)
    value = resp["Parameter"]["Value"]
    # StringList parameters are comma-delimited
    return [addr.strip() for addr in value.split(",") if addr.strip()]


def _build_email_body(report_date: str, cloudfront_domain: str) -> tuple[str, str]:
    """Return (subject, html_body) for the report notification email."""
    base_url = f"https://{cloudfront_domain}/reports/{report_date}/report_{report_date}"

    pdf_url  = f"{base_url}.pdf"
    html_url = f"{base_url}.html"
    json_url = f"{base_url}.json"

    subject = f"DNS Daily Report — {report_date}"

    html_body = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <style>
    body {{ font-family: Arial, sans-serif; color: #1a1a2e; padding: 24px; max-width: 620px; }}
    h2  {{ color: #0f3460; }}
    .links {{ margin-top: 20px; }}
    .links a {{
      display: inline-block;
      margin: 6px 8px 0 0;
      padding: 10px 20px;
      background: #0f3460;
      color: #fff;
      text-decoration: none;
      border-radius: 5px;
      font-size: 13px;
    }}
    .note {{ margin-top: 18px; font-size: 12px; color: #666; }}
    hr {{ border: none; border-top: 1px solid #e2e8f0; margin: 20px 0; }}
  </style>
</head>
<body>
  <h2>DNS Daily Report — {report_date}</h2>
  <p>Your daily DNS resolution report is ready. Download it in your preferred format:</p>

  <div class="links">
    <a href="{pdf_url}">📄 Download PDF</a>
    <a href="{html_url}">🌐 View HTML</a>
    <a href="{json_url}">{{ }} Raw JSON</a>
  </div>

  <p class="note">These links are permanent and will not expire.</p>
  <hr>
  <p style="font-size:11px; color:#999;">
    This report was generated automatically by the DNS log pipeline.
    Do not reply to this email.
  </p>
</body>
</html>"""

    return subject, html_body


def send_report_email(
    report_date: str,
    cloudfront_domain: str,
    sender_email: str,
    recipients_ssm_param: str,
) -> None:
    """
    Fetch recipients from SSM and send the report notification email via SES.

    Delivery failures for individual recipients are logged but do not raise —
    one bad email address should never abort the entire notification batch.
    """
    recipients = _get_recipients(recipients_ssm_param)
    if not recipients:
        logger.warning("No recipients found in SSM param '%s'. Skipping email.", recipients_ssm_param)
        return

    subject, html_body = _build_email_body(report_date, cloudfront_domain)

    logger.info("Sending report email for %s to %d recipient(s).", report_date, len(recipients))

    for recipient in recipients:
        try:
            ses.send_email(
                Source=sender_email,
                Destination={"ToAddresses": [recipient]},
                Message={
                    "Subject": {"Data": subject, "Charset": "UTF-8"},
                    "Body": {
                        "Html": {"Data": html_body, "Charset": "UTF-8"},
                    },
                },
            )
            logger.info("Email sent to %s", recipient)

        except Exception as exc:
            # Log and continue — don't let one invalid address kill the loop
            logger.error("Failed to send email to %s: %s", recipient, exc)
