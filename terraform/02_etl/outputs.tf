output "glue_database_name" {
  description = "Glue catalog database name used by Athena for all queries."
  value       = aws_glue_catalog_database.dns_analytics.name
}

output "processed_s3_bucket_name" {
  description = "S3 bucket containing Parquet-formatted, partitioned DNS logs."
  value       = aws_s3_bucket.processed_logs.id
}

output "processed_s3_bucket_arn" {
  description = "ARN of the processed logs S3 bucket."
  value       = aws_s3_bucket.processed_logs.arn
}

output "glue_job_name" {
  description = "Name of the Glue ETL job — used by Step Functions in layer 05."
  value       = aws_glue_job.dns_daily_etl.name
}

output "glue_crawler_name" {
  description = "Name of the Glue Crawler — used by Step Functions in layer 05."
  value       = aws_glue_crawler.dns_processed.name
}
