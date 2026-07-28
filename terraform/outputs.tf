output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "kubectl 연결 명령"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}
