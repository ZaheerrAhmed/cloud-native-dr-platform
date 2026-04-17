output "health_check_id"     { value = aws_route53_health_check.primary.id }
output "sns_topic_arn"       { value = var.sns_topic_arn }   # passed in from main.tf, not created here
output "primary_record_fqdn" { value = aws_route53_record.primary.fqdn }
