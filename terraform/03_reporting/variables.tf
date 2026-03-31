variable "aws_account_id" { type = string }
variable "aws_region"     { type = string; default = "us-east-1" }

variable "processed_s3_bucket_name" {
  description = "Processed Parquet logs bucket (from layer 02 output)."
  type        = string
}

variable "processed_s3_bucket_arn" {
  description = "ARN of the processed logs bucket (from layer 02 output)."
  type        = string
}

variable "glue_database_name" {
  description = "Glue catalog database name (from layer 02 output)."
  type        = string
  default     = "dns_analytics"
}
