variable "aws_account_id" {
  description = "AWS Account ID — used to ensure globally unique S3 bucket names."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy all ingestion resources into."
  type        = string
  default     = "us-east-1"
}
