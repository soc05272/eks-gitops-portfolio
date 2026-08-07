# cloudwatch-exporter용 IRSA — RDS 지표(CPUUtilization 등)는 CloudWatch에만 있어서
# Prometheus가 직접 수집할 수 없다. exporter가 CloudWatch API로 읽어와 Prometheus
# 형식으로 노출하면, 알람 경로가 하나로 통일된다(Prometheus → Alertmanager → Slack).
# 네 번째 IRSA — 패턴은 동일: 전용 Role을 해당 ServiceAccount에만 바인딩.

resource "aws_iam_policy" "cloudwatch_read" {
  name = "${var.project}-cloudwatch-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadMetrics"
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
      ]
      Resource = "*" # CloudWatch 지표 읽기는 리소스 단위 제한을 지원하지 않는다
    }]
  })
}

module "cloudwatch_exporter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.project}-cloudwatch-exporter"

  role_policy_arns = {
    read = aws_iam_policy.cloudwatch_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:cloudwatch-exporter"]
    }
  }
}
