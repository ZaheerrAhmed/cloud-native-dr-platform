output "cluster_name"         { value = aws_eks_cluster.main.name }
output "cluster_endpoint"     { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"           { value = aws_eks_cluster.main.certificate_authority[0].data }
output "oidc_provider_arn"    { value = aws_iam_openid_connect_provider.cluster.arn }
output "oidc_provider_url"    { value = aws_iam_openid_connect_provider.cluster.url }
output "velero_role_arn"      { value = aws_iam_role.velero.arn }
output "lb_controller_role_arn" { value = aws_iam_role.lb_controller.arn }
output "node_role_arn"        { value = aws_iam_role.node.arn }
