output "reports_bucket_name" { value = aws_s3_bucket.reports.id }
output "reports_bucket_arn"  { value = aws_s3_bucket.reports.arn }
output "lambda_function_arn" { value = aws_lambda_function.report_generator.arn }
output "lambda_function_name" { value = aws_lambda_function.report_generator.function_name }
output "athena_workgroup_name" { value = aws_athena_workgroup.dns_analytics.name }
output "lambda_role_name" { value = aws_iam_role.report_lambda.name }
output "lambda_role_arn"  { value = aws_iam_role.report_lambda.arn }
