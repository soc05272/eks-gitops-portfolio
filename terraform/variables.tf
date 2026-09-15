variable "project" {
  description = "리소스 이름/태그에 쓰이는 프로젝트 식별자"
  type = string
  default = "eks-gitops"
}

variable "region" {
  type = string
  default = "ap-northeast-2"
}

variable "vpc_cidr" {
  type = string
  default = "10.0.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes 버전"
  type = string
  default = "1.31"
}

variable "node_instance_type" {
  type = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type = number
  default = 2
}

variable "db_username" {
  type = string
  default = "appuser"
}

variable "db_password" {
  description = "RDS 마스터 비밀번호. TF_VAR_db_password 환경변수 또는 terraform.tfvars(gitignore 대상)로 주입"
  type = string
  sensitive = true
}

variable "api_allowed_cidrs" {
  description = "EKS API 퍼블릭 엔드포인트 접근을 허용할 CIDR 목록 (작업 PC의 공인 IP/32). tfvars로 주입"
  type = list(string)
}

variable "monthly_budget_usd" {
  description = "월 예산 상한(USD). 상시 가동 시 약 $164이므로 destroy 병행을 전제로 설정"
  type = string
  default = "40"
}

variable "budget_alert_email" {
  description = "예산 알림 수신 이메일 (공개 repo에 노출되지 않도록 tfvars로 주입)"
  type = string
}
