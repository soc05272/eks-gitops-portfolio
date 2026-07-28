variable "project" {
  description = "리소스 이름/태그에 쓰이는 프로젝트 식별자"
  type        = string
  default     = "eks-gitops"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes 버전"
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_password" {
  description = "RDS 마스터 비밀번호 (tfvars에 두지 말고 TF_VAR_db_password 환경변수로 주입)"
  type        = string
  sensitive   = true
}
