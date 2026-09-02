module "eks" {
  source = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name = "${var.project}-cluster"
  cluster_version = var.cluster_version

  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # 포트폴리오 환경이므로 로컬에서 kubectl 접근을 위해 퍼블릭 엔드포인트 허용
  cluster_endpoint_public_access = true

  # terraform을 실행한 IAM 주체에게 클러스터 관리자 권한 부여
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      capacity_type = "SPOT" # 비용 절감

      min_size = 1
      desired_size = var.node_desired_size
      max_size = 3
    }
  }
}
