# EBS CSI 드라이버 — PVC를 실제 EBS 볼륨으로 만들어주는 계층.
#
# 쿠버네티스 최신 버전은 in-tree AWS 볼륨 프로비저너가 제거되어, 드라이버 없이는
# PVC가 Pending에서 멈춘다. 4주차 Prometheus가 PV를 요구하므로 선행 설치.
# ALB 컨트롤러와 같은 패턴: 드라이버 파드가 AWS API(EBS 생성·attach)를 호출하므로
# IRSA로 전용 Role을 ServiceAccount(kube-system:ebs-csi-controller-sa)에 바인딩한다.

module "ebs_csi_irsa" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.project}-ebs-csi"
  attach_ebs_csi_policy = true # AWS 관리형 AmazonEBSCSIDriverPolicy 연결

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# EKS 관리형 애드온으로 설치 — 버전 관리·업그레이드를 EKS가 담당
resource "aws_eks_addon" "ebs_csi" {
  cluster_name = module.eks.cluster_name
  addon_name = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
}
