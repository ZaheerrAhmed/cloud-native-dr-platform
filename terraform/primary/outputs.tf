output "vpc_id"                  { value = module.vpc.vpc_id }
output "eks_cluster_name"        { value = module.eks.cluster_name }
output "eks_cluster_endpoint"    { value = module.eks.cluster_endpoint }
output "rds_primary_endpoint"    { value = module.rds.primary_endpoint }
output "rds_primary_arn"         { value = module.rds.primary_arn }
output "rds_secret_arn"          { value = module.rds.secret_arn }
output "velero_bucket"           { value = module.s3_velero.bucket_name }
output "ecr_repository_url"      { value = aws_ecr_repository.app.repository_url }
output "lambda_failover_arn"     { value = aws_lambda_function.failover.arn }
output "sns_topic_arn"           { value = aws_sns_topic.dr_alerts.arn }
output "velero_iam_role_arn"     { value = module.eks.velero_role_arn }
output "lb_controller_role_arn"  { value = module.eks.lb_controller_role_arn }
output "drift_detection_role_arn" { value = aws_iam_role.drift_detection.arn }

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.primary_region} --name ${module.eks.cluster_name}"
}
