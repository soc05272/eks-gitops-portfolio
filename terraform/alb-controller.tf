# AWS Load Balancer Controller용 IRSA(IAM Roles for Service Accounts) Role.
#
# 컨트롤러는 클러스터 안의 파드지만 ALB/타깃그룹/보안그룹을 만들려면 AWS API 권한이 필요하다.
# 노드 Role에 권한을 얹으면 노드 위 모든 파드가 그 권한을 갖게 되므로,
# EKS의 OIDC provider를 신뢰하는 전용 Role을 만들어 컨트롤러의 ServiceAccount에만 연결한다(IRSA).
#
# 정책 본문은 모듈이 공식 iam_policy.json과 동일한 내용을 내장하고 있어 별도 파일이 필요 없다.
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.project}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # kube-system 네임스페이스의 이 이름의 ServiceAccount만 이 Role을 쓸 수 있다
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
