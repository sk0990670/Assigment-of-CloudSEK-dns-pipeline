variable "aws_account_id" {
  description = "AWS Account ID."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "s3_raw_bucket_name" {
  description = "Name of the raw logs S3 bucket provisioned in layer 01."
  type        = string
}
