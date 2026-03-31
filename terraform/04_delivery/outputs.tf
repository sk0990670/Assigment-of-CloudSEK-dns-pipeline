output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.reports.id }
output "cloudfront_domain_name"     { value = aws_cloudfront_distribution.reports.domain_name }
output "ses_identity_arn"           { value = aws_ses_domain_identity.sender.arn }
output "recipients_ssm_param"       { value = aws_ssm_parameter.report_recipients.name }
