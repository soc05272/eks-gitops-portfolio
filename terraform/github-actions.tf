# GitHub Actions가 access key 없이 ECR에 푸시하기 위한 OIDC 연동.
#
# GitHub가 워크플로 실행마다 서명한 토큰을 발급하면, AWS가 그 토큰을 검증해
# 임시 자격증명을 내어준다. 장기 자격증명(access key)을 GitHub에 저장하지 않는 것이 핵심.
# 클러스터의 IRSA용 OIDC provider와는 별개다 — 그쪽은 "파드→AWS", 이쪽은 "GitHub→AWS".

module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "~> 5.0"
}

module "github_oidc_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-role"
  version = "~> 5.0"

  name = "${var.project}-gha-ecr"

  # 이 repo의 main 브랜치에서 실행된 워크플로만 이 Role을 쓸 수 있다
  subjects = ["soc05272/eks-gitops-portfolio:ref:refs/heads/main"]

  policies = {
    ecr_push = aws_iam_policy.gha_ecr_push.arn
  }
}

resource "aws_iam_policy" "gha_ecr_push" {
  name = "${var.project}-gha-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # 이 액션은 리소스 단위 제한을 지원하지 않는다
      },
      {
        Sid    = "PushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.app.arn # 이 프로젝트의 저장소에만
      },
    ]
  })
}
