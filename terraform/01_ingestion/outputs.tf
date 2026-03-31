output "firehose_stream_arn" {
  description = "ARN of the Kinesis Data Firehose delivery stream."
  value       = aws_kinesis_firehose_delivery_stream.dns_logs.arn
}

output "s3_raw_bucket_name" {
  description = "Name of the S3 bucket receiving raw DNS logs from Firehose."
  value       = aws_s3_bucket.raw_logs.id
}

output "s3_raw_bucket_arn" {
  description = "ARN of the S3 raw logs bucket."
  value       = aws_s3_bucket.raw_logs.arn
}
