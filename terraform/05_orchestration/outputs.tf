output "step_function_arn"  { value = aws_sfn_state_machine.dns_daily_pipeline.arn }
output "ops_sns_topic_arn"  { value = aws_sns_topic.ops_alerts.arn }
output "budget_name"        { value = aws_budgets_budget.pipeline_monthly.name }
output "scheduler_name"     { value = aws_scheduler_schedule.daily_pipeline.name }
