# GitHub Actions가 access key 없이 ECR에 푸시하기 위한 OIDC 연동.
#
# GitHub가 워크플로 실행마다 서명한 토큰을 발급하면, AWS가 그 토큰을 검증해
# 임시 자격증명을 내어준다. 장기 자격증명(access key)을 GitHub에 저장하지 않는 것이 핵심.
# 클러스터의 IRSA용 OIDC provider와는 별개다 — 그쪽은 "파드→AWS", 이쪽은 "GitHub→AWS".

module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "~> 5.0"
}

# Role은 모듈 대신 직접 정의한다. 이유(트러블슈팅 기록 참고):
# 1) GitHub의 새 sub 형식은 계정/저장소 "ID"를 포함한다 — repo:USER@계정ID/REPO@저장소ID:ref:...
#    모듈이 만드는 구형식 조건(repo:USER/REPO:ref:...)은 영원히 매치되지 않는다.
# 2) ID를 조건에 고정하면 계정명·repo명이 바뀌거나 탈취-재생성돼도 매치되지 않으므로 더 안전하다.
resource "aws_iam_role" "gha_ecr" {
  name = "${var.project}-gha-ecr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GithubOidcAuth"
      Effect = "Allow"
      Principal = {
        Federated = module.github_oidc_provider.arn
      }
      Action = ["sts:AssumeRoleWithWebIdentity"]
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # 이 repo(ID 고정)의 main 브랜치에서 실행된 워크플로만 허용
          "token.actions.githubusercontent.com:sub" = "repo:soc05272@107605885/eks-gitops-portfolio@1316360933:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gha_ecr" {
  role       = aws_iam_role.gha_ecr.name
  policy_arn = aws_iam_policy.gha_ecr_push.arn
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
