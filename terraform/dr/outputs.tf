output "vpc_id"                  { value = module.vpc.vpc_id }
output "eks_cluster_name"        { value = module.eks.cluster_name }
output "eks_cluster_endpoint"    { value = module.eks.cluster_endpoint }
output "rds_replica_endpoint"    { value = module.rds_replica.replica_endpoint }
output "velero_bucket_dr"        { value = module.s3_velero_dr.bucket_name }
output "velero_iam_role_arn"     { value = module.eks.velero_role_arn }
output "lb_controller_role_arn"  { value = module.eks.lb_controller_role_arn }

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.dr_region} --name ${module.eks.cluster_name}"
}
