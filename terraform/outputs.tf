output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "kafka_bootstrap_brokers_tls" {
  description = "Bootstrap servers for producer/consumer (TLS, port 9094)."
  value       = aws_msk_cluster.this.bootstrap_brokers_tls
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_actions_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.github_actions.arn
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}
