output "primary_endpoint"    { value = length(aws_db_instance.primary) > 0 ? aws_db_instance.primary[0].endpoint : "" }
output "primary_address"     { value = length(aws_db_instance.primary) > 0 ? aws_db_instance.primary[0].address : "" }
output "primary_arn"         { value = length(aws_db_instance.primary) > 0 ? aws_db_instance.primary[0].arn : "" }
output "replica_endpoint"    { value = length(aws_db_instance.replica) > 0 ? aws_db_instance.replica[0].endpoint : "" }
output "secret_arn"          { value = length(aws_secretsmanager_secret.db_password) > 0 ? aws_secretsmanager_secret.db_password[0].arn : "" }
output "rds_security_group_id" { value = aws_security_group.rds.id }
