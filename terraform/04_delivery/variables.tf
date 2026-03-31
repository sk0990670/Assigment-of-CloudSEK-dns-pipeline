variable "aws_account_id"      { type = string }
variable "aws_region"          { type = string; default = "us-east-1" }
variable "reports_bucket_name" { type = string }
variable "reports_bucket_arn"  { type = string }
variable "lambda_function_arn" { type = string }
variable "lambda_role_name"    { type = string }
variable "sender_domain"       {
  description = "Domain verified in SES for sending (e.g. 'example.com')."
  type        = string
}
