output "health_check_id"     { value = aws_route53_health_check.primary.id }
output "sns_topic_arn"       { value = var.sns_topic_arn }
output "primary_record_fqdn" { value = length(aws_route53_record.primary) > 0 ? aws_route53_record.primary[0].fqdn : "" }
