variable "aws_account_id"      { type = string }
variable "aws_region"          { type = string; default = "us-east-1" }
variable "glue_job_name"       { type = string }
variable "glue_crawler_name"   { type = string }
variable "lambda_function_arn" { type = string }
variable "lambda_function_name" { type = string }
variable "reports_bucket_arn"  { type = string }
